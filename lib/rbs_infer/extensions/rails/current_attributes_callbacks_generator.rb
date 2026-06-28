# frozen_string_literal: true

require "fileutils"
require "set"
require "yaml"
require "prism"
require "active_support/core_ext/string/inflections"
require_relative "before_action_scanner"
require_relative "partial_render_graph"
require_relative "erb_convention_generator/view_path_naming"
require_relative "../../ast/param_guarded_self_writes"
require_relative "../../signatures/rbs_parser_util"
require_relative "../../signatures/method_type_resolver"

module RbsInfer
  module Extensions
    module Rails
      # CurrentAttributes-side consumer of guarded-callback facts
      # (felixefelip/steep#41): when a guarded before_action handler writes
      # `Current.user = current_user`, every action running after it reads
      # a proven-present `Current.user`. This generator owns the
      # CurrentAttributes artifacts:
      #
      # - `populated_markers.rbs` — `Current::UserPopulated` marker modules
      #   declaring the populated attribute as proven present.
      # - `.steep_callbacks.yml` — `applies_constants` entries narrowing
      #   reads of the constant inside guarded actions.
      #
      # The PROOF comes from the auth layer: `resource_types` maps each
      # guard scope to the proven type of its helper (today emitted by the
      # Devise extension; any auth system able to assert "current_<scope>
      # is non-nil under the guard" can feed this). Keeping the consumer
      # here separates the CurrentAttributes domain from Devise's.
      class CurrentAttributesCallbacksGenerator
        attr_reader :app_dir, :output_dir, :scanner, :resource_types, :source_files

        # resource_types: { "user" => "(User & User::Validated)" } — the
        # proven (non-nil) type of `current_<scope>` under the guard.
        # source_files feed the MethodTypeResolver used to type transitive
        # writes (`Current.caderneta = value.caderneta`). Required (no
        # default): the resolver's universe must match the rest of the
        # pipeline — a derived `app/**/*.rb`-only default would silently
        # under-resolve (missing lib/engines).
        def initialize(app_dir:, output_dir:, scanner:, resource_types:, source_files:)
          @app_dir = app_dir
          @output_dir = output_dir
          @scanner = scanner
          @resource_types = resource_types
          @source_files = source_files
        end

        # Returns the populated-constant facts ([] when no guarded handler
        # populates a constant — nothing is written in that case). Each
        # fact carries its proven `:type`.
        def generate_all
          populated = populated_with_types
          markers_path = File.join(output_dir, "populated_markers.rbs")
          sidecar_path = File.join(output_dir, ".steep_callbacks.yml")

          if populated.empty?
            FileUtils.rm_f(markers_path)
            FileUtils.rm_f(sidecar_path)
            return []
          end

          FileUtils.mkdir_p(output_dir)
          File.write(markers_path, markers_rbs(populated))
          File.write(sidecar_path, sidecar_yaml(populated))
          populated
        end

        private

        # Direct writes (`Current.user = current_user`, type =
        # resource_types[scope]) plus the transitive writes the setter
        # override performs (`self.caderneta = value.caderneta`), each
        # carrying its resolved `:type` (felixefelip/steep#41).
        def populated_with_types
          direct = scanner.populated_constants.map do |c|
            c.merge(type: resource_types.fetch(c[:scope]))
          end

          (direct + direct.flat_map { |c| transitive_writes(c) }).uniq { |c| [c[:const_name], c[:attr], c[:scope]] }
        end

        # For a direct write `Const.attr = current_<scope>`, read Const's
        # `attr=` override and type its nil-guarded transitive self-writes
        # via the proven scope type.
        def transitive_writes(direct)
          setter = setter_override(direct[:const_name], "#{direct[:attr]}=")
          return [] unless setter

          base_type = resource_types.fetch(direct[:scope])
          RbsInfer::AST::ParamGuardedSelfWrites.extract(setter[:defn], setter[:param]).filter_map do |w|
            type = w[:value_method] ? resolve_method(base_type, w[:value_method]) : base_type
            next unless type

            {
              const_name: direct[:const_name],
              attr: w[:attr],
              scope: direct[:scope],
              defining_class: direct[:defining_class],
              type: RbsInfer::Signatures::RbsParserUtil.parenthesize_compound(type),
            }
          end
        end

        # Finds `def <method>(param) ... end` in the constant's source.
        # => { defn:, param: } or nil.
        def setter_override(const_name, method_name)
          path = File.join(app_dir, "app/models", "#{RbsInfer.class_name_to_path(const_name)}.rb")
          return nil unless File.exist?(path)

          result = Prism.parse(File.read(path))
          return nil unless result.success?

          defn = RbsInfer::Analyzer.find_all_nodes(result.value) do |n|
            n.is_a?(Prism::DefNode) && n.name.to_s == method_name && n.receiver.nil?
          end.first
          return nil unless defn

          param = defn.parameters&.requireds&.first
          return nil unless param.respond_to?(:name)

          { defn: defn, param: param.name.to_s }
        end

        def resolve_method(receiver_type, method_name)
          type = method_type_resolver.resolve(receiver_type, method_name)
          type if type && type != "untyped"
        end

        def method_type_resolver
          # Env-only constant resolver (no project SteepBridge here): the RBS env
          # is process-global, so transitively-resolved types derived from a
          # constant still get the constant's VALUE type, not its bare name (#56).
          @method_type_resolver ||= RbsInfer::Signatures::MethodTypeResolver.new(
            source_files,
            constant_resolver: RbsInfer::Inference::ConstantArgTypeResolver.new(
              steep_bridge: RbsInfer::Signatures::SteepBridge.new, caller_constant_types: {}
            )
          )
        end

        def markers_rbs(populated)
          lines = []
          lines << "# Generated by rbs_infer (current_attributes)"
          lines << "#"
          lines << "# Markers for `applies_constants` (felixefelip/steep#41): inside"
          lines << "# guarded actions, global state populated by a before_action"
          lines << "# handler is proven present."
          populated.group_by { |c| c[:const_name] }.each do |const_name, writes|
            lines << ""
            lines << "class #{const_name}"
            writes.uniq { |c| c[:attr] }.each_with_index do |c, idx|
              lines << "" if idx.positive?
              lines << "  module #{marker_name(c)}"
              lines << "    def #{c[:attr]}: () -> #{c[:type]}"
              lines << "  end"
            end
            lines << "end"
          end
          lines.join("\n") + "\n"
        end

        # One constants-only entry per guarded controller that descends
        # from the populating handler's class, plus the `toplevel: true`
        # entries for every ERB context (convention view or partial) reached
        # only through those guarded actions. The Devise-side sidecar carries
        # the `applies_self` narrowing for the same methods; the Steep
        # callbacks loader merges entries across sidecar files.
        def sidecar_yaml(populated)
          # Canonical marker order (direct writes before transitive) so every
          # stringified intersection lists markers the same way.
          @marker_order = populated.map { |c| marker_fqn(c) }.uniq
          facts = guarded_controller_facts(populated)

          controller_entries = facts.flat_map do |fact|
            applies = stringify_set_map(fact[:set_map])
            controller = fact[:controller]
            # The action carries the narrowing at its entry...
            controller_entry = {
              "class" => controller[:class_name],
              "applies_constants" => applies,
              "runs_before" => controller[:actions],
            }
            # ...and the convention view each guarded action renders sees the
            # same populated Current at its top-level body (the ERB class has
            # no method, so `toplevel: true` — felixefelip/steep#42).
            [controller_entry] + erb_view_entries(controller[:class_name], controller[:actions], applies)
          end

          entries = controller_entries + partial_toplevel_entries(facts)
          { "version" => 1, "callbacks" => entries }.to_yaml
        end

        # Guarded controllers that descend from a populating handler, each
        # paired with the marker set it proves present.
        # => [{ controller:, set_map: { const => Set[marker_fqn] } }, ...]
        def guarded_controller_facts(populated)
          scanner.guarded_controllers.filter_map do |controller|
            constants = populated.select do |p|
              p[:scope] == controller[:scope] && scanner.descends_from?(controller[:class_name], p[:defining_class])
            end
            next if constants.empty?

            { controller: controller, set_map: marker_set_map(constants) }
          end
        end

        # A constant can be populated in several attributes (the direct write
        # + transitive ones), each with its own marker module. Represent the
        # narrowing as a per-constant SET of marker FQNs so it can be
        # intersected across render sites before being stringified.
        def marker_set_map(constants)
          constants.group_by { |c| c[:const_name] }.transform_values do |cs|
            cs.map { |c| marker_fqn(c) }.uniq.to_set
          end
        end

        def marker_fqn(constant)
          "#{constant[:const_name]}::#{marker_name(constant)}"
        end

        # { const => Set[marker_fqn] } => { const => "singleton(C) & C::M1 & …" },
        # markers ordered canonically. Empty markers yield no key.
        def stringify_set_map(set_map)
          set_map.each_with_object({}) do |(const_name, markers), acc|
            next if markers.empty?

            ordered = markers.to_a.sort_by { |m| @marker_order.index(m) || Float::INFINITY }
            acc[const_name] = (["singleton(#{const_name})"] + ordered).join(" & ")
          end
        end

        # One `toplevel: true` entry per guarded action whose convention
        # view exists. Sound for convention views (rendered by that single
        # action). NOT emitted for partials/layouts (no single rendering
        # action) nor checked against explicit cross-renders by an
        # unguarded action — same heterogeneous-render scope as the issue.
        def erb_view_entries(controller_class, actions, applies)
          actions.filter_map do |action|
            erb_class = erb_view_class(controller_class, action)
            next unless erb_class

            # Fresh hash per entry — sharing `applies` would serialize as a
            # YAML alias.
            { "class" => erb_class, "applies_constants" => applies.dup, "toplevel" => true }
          end
        end

        # Convention view class for `Controller#action`, or nil when no
        # template file exists. `AdminUsersController#show` → app/views/
        # admin_users/show.html.erb → "ERBAdminUsersShow".
        def erb_view_class(controller_class, action)
          vr = convention_view_relative(controller_class, action)
          vr && view_path_naming.erb_class_name(vr)
        end

        # View-relative path of `Controller#action`'s convention template
        # ("admin_users/show.html.erb"), or nil when none exists.
        def convention_view_relative(controller_class, action)
          path = controller_class.sub(/Controller\z/, "").underscore
          return nil if path.empty?

          fmt = %w[html turbo_stream].find do |f|
            File.exist?(File.join(app_dir, "app/views", path, "#{action}.#{f}.erb"))
          end
          return nil unless fmt

          "#{path}/#{action}.#{fmt}.erb"
        end

        # `toplevel: true` entries for partials proven reachable ONLY through
        # guard-covered render sites (felixefelip/rbs_infer#25). Bails on the
        # whole set when the app has any unresolvable dynamic render — the
        # graph can't then be proven complete (see PartialRenderGraph).
        def partial_toplevel_entries(facts)
          graph = PartialRenderGraph.new(app_dir: app_dir).build
          return [] if graph.dynamic?

          covered = covered_partials(graph, convention_view_seed(facts))
          covered.sort.map do |view_relative, set_map|
            {
              "class" => view_path_naming.erb_class_name(view_relative),
              "applies_constants" => stringify_set_map(set_map),
              "toplevel" => true,
            }
          end
        end

        # Seed of the reachability fixpoint: each guarded action's convention
        # view (the file it renders) mapped to that action's proven markers.
        # => { "caderneta/index.html.erb" => { const => Set[marker_fqn] } }
        def convention_view_seed(facts)
          facts.each_with_object({}) do |fact, seed|
            fact[:controller][:actions].each do |action|
              vr = convention_view_relative(fact[:controller][:class_name], action)
              seed[vr] = fact[:set_map] if vr
            end
          end
        end

        # Fixpoint over the render graph: a partial is covered iff it isn't
        # rendered externally (controller/layout) and ALL of its render sites
        # are themselves covered — its markers are the intersection across
        # those sites. Partials in an uncovered cycle never enter `covered`.
        # => { partial_file_view_relative => { const => Set[marker_fqn] } }
        def covered_partials(graph, seed)
          covered = seed.dup

          loop do
            progressed = false
            graph.partial_files.each do |partial_key, view_relative|
              next if covered.key?(view_relative) || graph.external.include?(partial_key)

              sites = graph.renderers_of(partial_key)
              site_maps = sites.map { |s| covered[s] }
              next if sites.empty? || site_maps.any?(&:nil?)

              merged = intersect_set_maps(site_maps)
              next if merged.empty?

              covered[view_relative] = merged
              progressed = true
            end
            break unless progressed
          end

          covered.reject { |view_relative, _| seed.key?(view_relative) }
        end

        # Per-constant intersection of marker sets: a constant survives only
        # if every site narrows it, with the markers common to all sites.
        def intersect_set_maps(maps)
          common_consts = maps.map(&:keys).reduce(:&) || []
          common_consts.each_with_object({}) do |const_name, acc|
            markers = maps.map { |m| m[const_name] }.reduce(:&)
            acc[const_name] = markers unless markers.empty?
          end
        end

        # Stateless holder for `ViewPathNaming#erb_class_name` (view path →
        # ERB class name), reused without dragging in the ERB generator.
        def view_path_naming
          @view_path_naming ||= Object.new.extend(ErbConventionGenerator::ViewPathNaming)
        end

        def marker_name(constant)
          "#{constant[:attr].camelize}Populated"
        end
      end
    end
  end
end
