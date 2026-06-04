# frozen_string_literal: true

require "prism"
require "fileutils"
require "yaml"
require "active_support/core_ext/string/inflections"
require_relative "before_action_scanner"

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
          guarded = scanner.guarded_controllers
          sidecar_path = File.join(output_dir, ".steep_callbacks.yml")

          if guarded.empty?
            FileUtils.rm_f(sidecar_path)
            return
          end

          entries = guarded.map do |entry|
            marker = "#{MODULE_NAME}::#{authenticated_marker_name(entry[:scope])}"
            {
              "class" => entry[:class_name],
              "applies_self" => "#{entry[:class_name]} & #{marker}",
              "runs_before" => entry[:actions],
            }
          end

          File.write(sidecar_path, { "version" => 1, "callbacks" => entries }.to_yaml)
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
            klass = entry[:class_name]
            lines << "" if idx.positive?
            # `current_*` is nil when unauthenticated; `authenticate_*!`
            # either returns the resource or throws :warden (redirect).
            lines << "  def current_#{scope}: () -> #{klass}?"
            lines << ""
            lines << "  def authenticate_#{scope}!: (?::Hash[::Symbol, untyped] opts) -> #{klass}"
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
            "    def current_#{scope}: () -> #{entry[:class_name]}",
            "",
            "    def #{scope}_signed_in?: () -> true",
            "  end",
          ]
        end

        def authenticated_marker_name(scope)
          "#{scope.camelize}Authenticated"
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
