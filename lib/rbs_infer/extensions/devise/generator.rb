# frozen_string_literal: true

require "prism"
require "fileutils"
require "yaml"
require "active_support/core_ext/string/inflections"
require_relative "before_action_scanner"
require_relative "../../rbs_parser_util"

module RbsInfer
  module Extensions
    module Devise
      # Generates RBS for Devise's per-scope controller helpers.
      #
      # `Devise::Controllers::Helpers.define_helpers(mapping)` class_evals
      # `current_#{scope}`, `authenticate_#{scope}!`, `#{scope}_signed_in?`
      # and `#{scope}_session` at boot — one set per `devise_for` mapping —
      # so no `def` ever exists in source and static analysis can't see
      # them. The scopes themselves ARE statically readable from
      # `devise_for` declarations in config/routes.rb, and the helper
      # types are mechanical per scope:
      #
      #   devise_for :users   →  def current_user: () -> User?
      #                          def authenticate_user!: (...) -> User
      #                          def user_signed_in?: () -> bool
      #                          def user_session: () -> untyped
      #
      # Scope/class derivation mirrors Devise::Mapping#initialize:
      # singular = options[:singular] || resource.singularize;
      # class    = options[:class_name] || resource.classify.
      #
      # Complements the static `DeviseCustom` module emitted by the
      # rails_custom extension (scope-independent helpers: `resource`,
      # path helpers, etc.).
      class Generator
        MODULE_NAME = "DeviseScopedHelpers"

        attr_reader :app_dir, :output_dir, :routes_path

        def initialize(app_dir:, output_dir:, routes_path: nil)
          @app_dir = app_dir
          @output_dir = output_dir
          @routes_path = routes_path || File.join(app_dir, "config/routes.rb")
        end

        # Returns the list of generated scopes ([] when the app has no
        # `devise_for` — nothing is written in that case).
        #
        # The ApplicationController reopen lives in its own
        # `application_controller.rbs`: MethodTypeResolver's RBS lookup
        # matches sig files by class-name path first, so the include is
        # only discovered when the filename matches the class (same
        # convention as the rails_custom extension).
        def generate_all
          scopes = parse_scopes
          return [] if scopes.empty?

          FileUtils.mkdir_p(output_dir)
          File.write(File.join(output_dir, "devise_scoped_helpers.rbs"), helpers_rbs(scopes))
          File.write(File.join(output_dir, "application_controller.rbs"), controller_rbs)
          write_callbacks_sidecar(scopes)
          scopes
        end

        # `.steep_callbacks.yml` (felixefelip/steep#27): inside actions
        # guarded by `before_action :authenticate_<scope>!`, `self` is
        # narrowed with the `<Scope>Authenticated` marker — so
        # `current_<scope>` is proven non-nil right at method entry, the
        # same mechanism as the AR after-validation narrowing.
        def write_callbacks_sidecar(scopes)
          scanner = BeforeActionScanner.new(app_dir: app_dir, scopes: scopes.map { |s| s[:scope] })
          sidecar_path = File.join(output_dir, ".steep_callbacks.yml")
          populated = scanner.populated_constants
          scope_classes = scopes.to_h { |s| [s[:scope], s[:class_name]] }

          # Actions of guarded controllers + before_action handlers declared
          # after the guard (e.g. `set_authenticated_user` runs with
          # current_user proven present). Actions also get
          # `applies_constants` when a guarded handler populates global
          # state (`Current.user = current_user`) — felixefelip/steep#41.
          entries =
            scanner.guarded_controllers.map do |e|
              constants = populated.select do |p|
                p[:scope] == e[:scope] && scanner.descends_from?(e[:class_name], p[:defining_class])
              end
              callback_entry(e[:class_name], e[:scope], e[:actions], constants: constants)
            end +
            scanner.guarded_handlers.map { |e| callback_entry(e[:class_name], e[:scope], e[:handlers]) }

          if entries.empty?
            FileUtils.rm_f(sidecar_path)
            return
          end

          write_populated_markers(populated, scope_classes)
          File.write(sidecar_path, { "version" => 1, "callbacks" => entries }.to_yaml)
        end

        def callback_entry(class_name, scope, methods, constants: [])
          marker = "#{MODULE_NAME}::#{authenticated_marker_name(scope)}"
          entry = {
            "class" => class_name,
            "applies_self" => "#{class_name} & #{marker}",
            "runs_before" => methods,
          }
          unless constants.empty?
            entry["applies_constants"] = constants.to_h do |c|
              [c[:const_name], "singleton(#{c[:const_name]}) & #{populated_marker_type(c)}"]
            end
          end
          entry
        end

        # `Current::UserPopulated` — marker intersected into the constant's
        # singleton inside guarded actions; declares the populated attribute
        # as proven present (same decorated type as current_<scope>).
        def write_populated_markers(populated, scope_classes)
          path = File.join(output_dir, "populated_markers.rbs")
          if populated.empty?
            FileUtils.rm_f(path)
            return
          end

          lines = []
          lines << "# Generated by rbs_infer (devise)"
          lines << "#"
          lines << "# Markers for `applies_constants` (felixefelip/steep#41): inside"
          lines << "# guarded actions, global state populated by a before_action"
          lines << "# handler is proven present."
          populated.group_by { |c| c[:const_name] }.each do |const_name, writes|
            lines << ""
            lines << "class #{const_name}"
            writes.uniq { |c| c[:attr] }.each_with_index do |c, idx|
              lines << "" if idx.positive?
              lines << "  module #{populated_marker_name(c)}"
              lines << "    def #{c[:attr]}: () -> #{wrap(resource_type(scope_classes.fetch(c[:scope])))}"
              lines << "  end"
            end
            lines << "end"
          end
          File.write(path, lines.join("\n") + "\n")
        end

        def populated_marker_name(constant)
          "#{constant[:attr].camelize}Populated"
        end

        def populated_marker_type(constant)
          "#{constant[:const_name]}::#{populated_marker_name(constant)}"
        end

        # Extracts [{scope:, class_name:}, ...] from `devise_for` calls.
        def parse_scopes
          return [] unless File.exist?(routes_path)

          source = File.read(routes_path)
          return [] unless source.include?("devise_for")

          result = Prism.parse(source)
          return [] unless result.success?

          calls = RbsInfer::Analyzer.find_all_nodes(result.value) do |node|
            node.is_a?(Prism::CallNode) && node.name == :devise_for && node.receiver.nil? && node.arguments
          end

          calls.flat_map { |call| scopes_from_call(call) }.uniq
        end

        private

        # `devise_for :users, :admins, class_name: "Account"` — every
        # SymbolNode is a resource; keyword options apply to all of them
        # (same as Devise's `devise_for(*resources)`).
        def scopes_from_call(call)
          resources = []
          options = {}

          call.arguments.arguments.each do |arg|
            case arg
            when Prism::SymbolNode
              resources << arg.value.to_s
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)
                options[elem.key.value.to_sym] = literal_value(elem.value)
              end
            end
          end

          resources.map do |resource|
            scoped_path = (options[:as] || resource).to_s.tr("/", "_")
            {
              scope: (options[:singular] || scoped_path.singularize).to_s,
              class_name: (options[:class_name] || resource.classify).to_s,
            }
          end
        end

        def literal_value(node)
          case node
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.value.to_s
          end
        end

        def helpers_rbs(scopes)
          lines = []
          lines << "# Generated by rbs_infer (devise)"
          lines << "#"
          lines << "# Per-scope Devise controller helpers. Devise class_evals these at"
          lines << "# boot (Devise::Controllers::Helpers.define_helpers), so they are"
          lines << "# invisible to static analysis; the scopes come from `devise_for`"
          lines << "# declarations in config/routes.rb."
          lines << ""
          lines << "module #{MODULE_NAME}"
          scopes.each_with_index do |entry, idx|
            scope = entry[:scope]
            resource = resource_type(entry[:class_name])
            lines << "" if idx.positive?
            # `current_*` is nil when unauthenticated; `authenticate_*!`
            # either returns the resource or throws :warden (redirect).
            lines << "  def current_#{scope}: () -> #{optional(resource)}"
            lines << ""
            lines << "  def authenticate_#{scope}!: (?::Hash[::Symbol, untyped] opts) -> #{wrap(resource)}"
            lines << ""
            lines << "  def #{scope}_signed_in?: () -> bool"
            lines << ""
            lines << "  def #{scope}_session: () -> untyped"
          end
          scopes.each do |entry|
            lines << ""
            lines.concat(authenticated_marker_lines(entry))
          end
          lines << "end"
          lines.join("\n") + "\n"
        end

        # Marker intersected into `self` by the callbacks sidecar (and
        # available to any future `unconditional.self` postcondition):
        # under `authenticate_<scope>!`, the resource is proven present.
        def authenticated_marker_lines(entry)
          scope = entry[:scope]
          [
            "  # Receiver narrowed under `authenticate_#{scope}!`.",
            "  module #{authenticated_marker_name(scope)}",
            "    def current_#{scope}: () -> #{wrap(resource_type(entry[:class_name]))}",
            "",
            "    def #{scope}_signed_in?: () -> true",
            "  end",
          ]
        end

        def authenticated_marker_name(scope)
          "#{scope.camelize}Authenticated"
        end

        # The resource comes from the DB (warden → serialize_from_session
        # → finder), the same provenance that makes the fork's finders
        # return `Model & Model::Validated`. Decorate identically — but
        # only when rbs_rails actually emitted the marker (models without
        # unconditional validations have no `::Validated`; referencing a
        # missing type would poison the RBS environment).
        def resource_type(class_name)
          validated_marker?(class_name) ? "#{class_name} & #{class_name}::Validated" : class_name
        end

        def validated_marker?(class_name)
          @validated_markers ||= {}
          return @validated_markers[class_name] if @validated_markers.key?(class_name)

          target = "#{class_name}::Validated"
          @validated_markers[class_name] = Dir[File.join(app_dir, "sig/**/*.rbs")].any? do |rbs_file|
            content = File.read(rbs_file)
            next false unless content.include?("::Validated")

            RbsParserUtil.build_declaration_index(RbsParserUtil.parse_declarations(content)).key?(target)
          end
        end

        # Intersections need parens in method-type position and before `?`.
        def wrap(type)
          type.include?("&") ? "(#{type})" : type
        end

        def optional(type)
          "#{wrap(type)}?"
        end

        def controller_rbs
          <<~RBS
            # Generated by rbs_infer (devise)

            class ApplicationController
              include #{MODULE_NAME}
            end
          RBS
        end
      end
    end
  end
end
