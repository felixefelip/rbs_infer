# frozen_string_literal: true

require "fileutils"
require "yaml"
require "prism"
require "active_support/core_ext/string/inflections"
require_relative "before_action_scanner"
require_relative "transitive_constant_writes"
require_relative "../../rbs_parser_util"
require_relative "../../method_type_resolver"

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
          TransitiveConstantWrites.extract(setter[:defn], setter[:param]).filter_map do |w|
            type = w[:value_method] ? resolve_method(base_type, w[:value_method]) : base_type
            next unless type

            {
              const_name: direct[:const_name],
              attr: w[:attr],
              scope: direct[:scope],
              defining_class: direct[:defining_class],
              type: RbsParserUtil.parenthesize_compound(type),
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
          @method_type_resolver ||= RbsInfer::MethodTypeResolver.new(source_files)
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
        # from the populating handler's class. The Devise-side sidecar
        # carries the `applies_self` narrowing for the same methods; the
        # Steep callbacks loader merges entries across sidecar files.
        def sidecar_yaml(populated)
          entries = scanner.guarded_controllers.filter_map do |controller|
            constants = populated.select do |p|
              p[:scope] == controller[:scope] && scanner.descends_from?(controller[:class_name], p[:defining_class])
            end
            next if constants.empty?

            {
              "class" => controller[:class_name],
              # A constant can be populated in several attributes (the
              # direct write + transitive ones), each with its own marker
              # module — intersect them all, else only one would narrow.
              "applies_constants" => constants.group_by { |c| c[:const_name] }.transform_values do |cs|
                markers = cs.map { |c| "#{c[:const_name]}::#{marker_name(c)}" }.uniq
                (["singleton(#{cs.first[:const_name]})"] + markers).join(" & ")
              end,
              "runs_before" => controller[:actions],
            }
          end

          { "version" => 1, "callbacks" => entries }.to_yaml
        end

        def marker_name(constant)
          "#{constant[:attr].camelize}Populated"
        end
      end
    end
  end
end
