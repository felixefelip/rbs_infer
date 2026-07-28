# frozen_string_literal: true

require "prism"
require "fileutils"
require "active_support/core_ext/string/inflections"
require_relative "../rails/before_action_scanner"
require_relative "../../signatures/rbs_parser_util"

module RbsInfer
  module Extensions
    module Devise
      # Emits *pseudo-code* (one plain `.rb` under `sig/generated/steep_devise_runtime/`)
      # for Devise's per-scope controller helpers — the same Forma-2 idea as the AR,
      # controller and view runtime sidecars.
      #
      # `Devise::Controllers::Helpers.define_helpers(mapping)` class_evals
      # `current_#{scope}`, `authenticate_#{scope}!`, `#{scope}_signed_in?` and
      # `#{scope}_session` at boot — one set per `devise_for` mapping, into a module
      # included in `ActionController::Base` — so no `def` ever exists in source and
      # static analysis can't see them. The scopes themselves ARE statically readable from
      # `devise_for` declarations in config/routes.rb.
      #
      # Scope/class derivation mirrors Devise::Mapping#initialize:
      # singular = options[:singular] || resource.singularize;
      # class    = options[:class_name] || resource.classify.
      #
      # ## Why pseudo-code and not RBS
      #
      # The generator used to emit the helpers' RBS directly, plus a `<Scope>Authenticated`
      # marker module and a `.steep_callbacks.yml` intersecting that marker into `self` for
      # the actions of every guarded controller. That meant *computing* two facts it had no
      # business computing:
      #
      #   * the resource's proven type — it scanned `sig/**/*.rbs` for a `<Model>::Validated`
      #     marker to decide whether to decorate it;
      #   * which controllers may assume the resource is present — it re-derived the
      #     `before_action` chain, `only:`/`except:` and `skip_before_action` itself.
      #
      # Written as the plain Ruby it behaves like, BOTH fall out of machinery that already
      # exists. `current_<scope>` is a finder, so rbs_rails' signature is what makes it
      # `(Model & Model::Validated)?`. `authenticate_<scope>!` halts on the nil branch, so
      # the postconditions inferrer is what turns "did not halt" into `current_<scope>`
      # being non-nil — and the controller-runtime pseudo-code, which already inlines the
      # effective callback chain with a halt check after each link, is what carries that to
      # the action. Nothing here states a type or names a controller.
      #
      # `proven_resource_types` / `build_scanner` survive for a different consumer,
      # `Rails::CurrentAttributesCallbacksGenerator` — Current narrowing is not a Devise
      # concern and still works off the scanner.
      class Generator
        MODULE_NAME = "DeviseScopedHelpers"

        # The host Devise itself includes the helpers into
        # (`ActiveSupport.on_load(:action_controller)`), which is also why this generator
        # never has to name ApplicationController.
        HOST_CLASS = "ActionController::Base"

        # NOT dot-prefixed: `.rb` SOURCE the analyzer and the Steep fork read via
        # `sig/**/*.rb` (`**` skips hidden dirs).
        SIDECAR_DIR = "sig/generated/steep_devise_runtime"
        FILENAME = "devise_scoped_helpers.rb"

        attr_reader :app_dir, :output_dir, :routes_path

        def initialize(app_dir:, output_dir:, routes_path: nil)
          @app_dir = app_dir
          @output_dir = output_dir
          @routes_path = routes_path || File.join(app_dir, "config/routes.rb")
        end

        # => [{ filename:, source: }] (empty when the app has no `devise_for`).
        def build
          scopes = parse_scopes
          return [] if scopes.empty?

          [{ filename: FILENAME, source: pseudo_code(scopes) }]
        end

        # Writes the sidecar dir, removing a stale one when nothing qualifies. Returns the
        # list of generated scopes ([] when the app has no `devise_for`).
        def generate_all
          files = build
          FileUtils.rm_rf(output_dir)

          unless files.empty?
            FileUtils.mkdir_p(output_dir)
            files.each { |file| File.write(File.join(output_dir, file[:filename]), file[:source]) }
          end

          parse_scopes
        end

        # ── Auth-layer facts consumed by other generators ─────────────
        # (e.g. Rails::CurrentAttributesCallbacksGenerator)

        def build_scanner(scopes = parse_scopes)
          Rails::BeforeActionScanner.new(app_dir: app_dir, scopes: scopes.map { |s| s[:scope] })
        end

        # { "user" => "(User & User::Validated)" } — the proven (non-nil)
        # type of `current_<scope>` under the guard.
        def proven_resource_types(scopes = parse_scopes)
          scopes.to_h { |s| [s[:scope], RbsInfer::Signatures::RbsParserUtil.parenthesize_compound(resource_type(s[:class_name]))] }
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

        def pseudo_code(scopes)
          lines = []
          lines << "# frozen_string_literal: true"
          lines << "#"
          lines << "# GENERATED by RbsInfer::Extensions::Devise::Generator."
          lines << "# Regenerated on every run; do not edit."
          lines << "#"
          lines << "# Devise class_evals one set of these per `devise_for` mapping at boot"
          lines << "# (Devise::Controllers::Helpers.define_helpers), so no `def` exists in source."
          lines << "# This is that module written as the plain Ruby it behaves like: the analyzer"
          lines << "# reads it to INFER the helpers' RBS, and the checker reads it to INFER what an"
          lines << "# action guarded by `authenticate_<scope>!` may assume on entry."
          lines << "#"
          lines << "# Nothing below states a type."
          lines << ""
          lines << "module #{MODULE_NAME}"
          # Warden's helpers run as controller instance methods. Without this, `self` in
          # the module body is BasicObject and neither `session` nor the `redirect_to`
          # that records the halt resolves — the halt is the whole point.
          lines << "  # @type instance: #{HOST_CLASS}"
          scopes.each do |entry|
            lines << ""
            lines.concat(scope_lines(entry))
          end
          lines << "end"
          lines << ""
          # Where Devise puts them: `ActiveSupport.on_load(:action_controller)`. Reopening
          # the framework class (rather than ApplicationController) also means the app's
          # own base controller is never named, let alone rewritten.
          lines << "module ActionController"
          lines << "  class Base"
          lines << "    include #{MODULE_NAME}"
          lines << "  end"
          lines << "end"
          lines.join("\n") + "\n"
        end

        def scope_lines(entry)
          scope = entry[:scope]
          [
            # Warden deserializes the record from the session on first read. A finder is
            # what it amounts to, and it is where the resource's type comes from — nilable
            # because an unauthenticated request has no record.
            "  def current_#{scope}",
            "    #{entry[:class_name]}.find_by(id: session[#{session_key(scope).inspect}])",
            "  end",
            "",
            # `warden.authenticate!` throws :warden, which Devise turns into a redirect to
            # the sign-in page. `redirect_to` is the vocabulary the controller-runtime
            # pseudo-code already uses for "this halts the request", and the halt is what
            # the postconditions inferrer reads: past it, `current_#{scope}` is non-nil.
            "  def authenticate_#{scope}!",
            "    unless current_#{scope}",
            "      redirect_to(\"/\")",
            "      return",
            "    end",
            "",
            "    current_#{scope}",
            "  end",
            "",
            "  def #{scope}_signed_in?",
            "    current_#{scope} ? true : false",
            "  end",
            "",
            "  def #{scope}_session",
            "    session",
            "  end",
          ]
        end

        # Warden's session key for a scope (`warden.user.account.key`).
        def session_key(scope)
          "warden.user.#{scope}.key"
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

            RbsInfer::Signatures::RbsParserUtil.build_declaration_index(RbsInfer::Signatures::RbsParserUtil.parse_declarations(content)).key?(target)
          end
        end
      end
    end
  end
end
