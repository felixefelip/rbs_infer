# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Devise
      # Scans app/controllers for `before_action :authenticate_<scope>!`
      # declarations and resolves, per concrete controller, which actions
      # run under the guard — the input for the `.steep_callbacks.yml`
      # sidecar (felixefelip/steep#27).
      #
      # Inheritance is resolved within the app: a guard declared in
      # ApplicationController applies to every subclass unless a
      # `skip_before_action` drops it. `only:`/`except:` filter the
      # guarded action list. Controllers whose superclass chain leaves
      # the app (e.g. `Users::RegistrationsController <
      # Devise::RegistrationsController`) are conservatively skipped —
      # Devise's own controllers manage authentication themselves.
      class BeforeActionScanner
        ControllerInfo = Struct.new(
          :class_name, :superclass_name, :actions,
          :guards, :skips, keyword_init: true
        )

        def initialize(app_dir:, scopes:)
          @app_dir = app_dir
          # ["user", "admin", ...] → guard method names to look for
          @guard_methods = scopes.to_h { |s| ["authenticate_#{s}!", s] }
        end

        # Returns [{class_name:, scope:, actions: [...]}, ...] — one entry
        # per controller with at least one guarded action.
        def guarded_controllers
          controllers = parse_controllers

          controllers.values.filter_map do |info|
            next if info.actions.empty?

            scope, filter = effective_guard(info, controllers)
            next unless scope

            actions = apply_filter(info.actions, filter)
            actions = drop_skips(actions, info, controllers)
            next if actions.empty?

            { class_name: info.class_name, scope: scope, actions: actions }
          end
        end

        private

        def parse_controllers
          controllers = {}

          Dir.glob(File.join(@app_dir, "app/controllers/**/*.rb")).sort.each do |path|
            result = Prism.parse(File.read(path))
            next unless result.success?

            RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::ClassNode) }.each do |klass|
              info = build_info(klass)
              controllers[info.class_name] = info if info
            end
          end

          controllers
        end

        def build_info(klass)
          name = RbsInfer::Analyzer.extract_constant_path(klass.constant_path)
          return nil unless name

          superclass = klass.superclass && RbsInfer::Analyzer.extract_constant_path(klass.superclass)

          info = ControllerInfo.new(
            class_name: name, superclass_name: superclass,
            actions: [], guards: [], skips: []
          )

          statements = case klass.body
                       when Prism::StatementsNode then klass.body.body
                       when nil then []
                       else [klass.body]
                       end

          visibility = :public
          statements.each do |stmt|
            case stmt
            when Prism::DefNode
              info.actions << stmt.name.to_s if visibility == :public && stmt.receiver.nil?
            when Prism::CallNode
              case stmt.name
              when :private, :protected
                visibility = stmt.name if stmt.arguments.nil?
              when :before_action
                guard = extract_guard(stmt)
                info.guards << guard if guard
              when :skip_before_action
                skip = extract_guard(stmt)
                info.skips << skip if skip
              end
            end
          end

          info
        end

        # `before_action :authenticate_user!, only: [:show]` →
        # { scope: "user", only: ["show"], except: nil }; nil when the
        # call doesn't reference a known guard method.
        def extract_guard(call)
          return nil unless call.arguments

          scope = nil
          only = nil
          except = nil

          call.arguments.arguments.each do |arg|
            case arg
            when Prism::SymbolNode
              scope ||= @guard_methods[arg.value.to_s]
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)
                case elem.key.value.to_s
                when "only" then only = symbol_list(elem.value)
                when "except" then except = symbol_list(elem.value)
                end
              end
            end
          end

          scope ? { scope: scope, only: only, except: except } : nil
        end

        def symbol_list(node)
          nodes = node.is_a?(Prism::ArrayNode) ? node.elements : [node]
          nodes.filter_map { |n| n.value.to_s if n.is_a?(Prism::SymbolNode) }
        end

        # Walks the superclass chain (within the app) looking for the
        # nearest guard. Chains that leave the app resolve to no guard.
        def effective_guard(info, controllers, visited = Set.new)
          return [nil, nil] if visited.include?(info.class_name)
          visited << info.class_name

          own = info.guards.first
          return [own[:scope], own] if own

          parent = controllers[info.superclass_name]
          return [nil, nil] unless parent

          effective_guard(parent, controllers, visited)
        end

        def apply_filter(actions, guard)
          result = actions
          result &= guard[:only] if guard[:only]
          result -= guard[:except] if guard[:except]
          result
        end

        # `skip_before_action :authenticate_user!` on the controller (or
        # any ancestor between it and the guard) drops actions from the
        # guarded list. `only:` on the skip limits which actions are
        # dropped; `except:` keeps those guarded.
        def drop_skips(actions, info, controllers, visited = Set.new)
          return actions if visited.include?(info.class_name)
          visited << info.class_name

          info.skips.each do |skip|
            dropped = if skip[:only]
                        skip[:only]
                      elsif skip[:except]
                        actions - skip[:except]
                      else
                        actions
                      end
            actions -= dropped
          end

          parent = controllers[info.superclass_name]
          parent ? drop_skips(actions, parent, controllers, visited) : actions
        end
      end
    end
  end
end
