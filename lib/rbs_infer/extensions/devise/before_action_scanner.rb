# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Devise
      # Scans app/controllers for `before_action :authenticate_<scope>!`
      # declarations and resolves what runs under the guard — the input
      # for the `.steep_callbacks.yml` sidecar (felixefelip/steep#27):
      #
      # - actions: every public action of a guarded controller.
      # - handlers: `before_action` handlers declared AFTER the guard in
      #   the effective callback chain (ancestors run first, then own
      #   declarations in order) — e.g. `set_authenticated_user` runs
      #   with `current_user` already proven present.
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
          :class_name, :superclass_name, :actions, :defs,
          :chain, :skips, keyword_init: true
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

        # before_action handlers declared after an unconditional guard run
        # with the resource proven present, so they get the same narrowing
        # — attributed to the class that DEFINES the handler (where Steep
        # type-checks its body).
        #
        # Returns [{class_name:, scope:, handlers: [...]}, ...].
        #
        # Soundness guard: any `skip_before_action` of the guard anywhere
        # in the app could let a handler run unguarded in that subclass,
        # so handler narrowing is dropped entirely for that scope
        # (conservative — per-action interplay isn't worth modeling).
        def guarded_handlers
          controllers = parse_controllers
          skipped_scopes = collect_skipped_scopes(controllers)

          by_class = Hash.new { |h, k| h[k] = {} }

          controllers.each_value do |info|
            chain = effective_chain(info, controllers)
            guard_index = chain.index do |entry|
              entry[:scope] && entry[:only].nil? && entry[:except].nil?
            end
            next unless guard_index

            scope = chain[guard_index][:scope]
            next if skipped_scopes.include?(scope)

            chain.drop(guard_index + 1).each do |entry|
              entry[:handlers].each do |handler|
                next if @guard_methods.key?(handler)

                owner = defining_class(handler, info, controllers)
                next unless owner

                (by_class[owner][scope] ||= []) << handler
              end
            end
          end

          by_class.flat_map do |class_name, scopes|
            scopes.map do |scope, handlers|
              { class_name: class_name, scope: scope, handlers: handlers.uniq.sort }
            end
          end.sort_by { |entry| entry[:class_name] }
        end

        private

        def parse_controllers
          @parse_controllers ||= begin
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
        end

        def build_info(klass)
          name = RbsInfer::Analyzer.extract_constant_path(klass.constant_path)
          return nil unless name

          superclass = klass.superclass && RbsInfer::Analyzer.extract_constant_path(klass.superclass)

          info = ControllerInfo.new(
            class_name: name, superclass_name: superclass,
            actions: [], defs: [], chain: [], skips: []
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
              next unless stmt.receiver.nil?
              info.defs << stmt.name.to_s
              info.actions << stmt.name.to_s if visibility == :public
            when Prism::CallNode
              case stmt.name
              when :private, :protected
                visibility = stmt.name if stmt.arguments.nil?
              when :before_action
                entry = extract_callback(stmt)
                info.chain << entry if entry
              when :skip_before_action
                skip = extract_callback(stmt)
                info.skips << skip if skip&.fetch(:scope)
              end
            end
          end

          info
        end

        # `before_action :authenticate_user!, :set_locale, only: [:show]` →
        # { handlers: [...], scope: "user"|nil, only:, except: }. `scope`
        # is set when any handler is a known guard method.
        def extract_callback(call)
          return nil unless call.arguments

          handlers = []
          only = nil
          except = nil

          call.arguments.arguments.each do |arg|
            case arg
            when Prism::SymbolNode
              handlers << arg.value.to_s
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

          return nil if handlers.empty?

          scope = handlers.filter_map { |h| @guard_methods[h] }.first
          { handlers: handlers, scope: scope, only: only, except: except }
        end

        def symbol_list(node)
          nodes = node.is_a?(Prism::ArrayNode) ? node.elements : [node]
          nodes.filter_map { |n| n.value.to_s if n.is_a?(Prism::SymbolNode) }
        end

        # Callback chain in execution order: ancestors' declarations run
        # before the subclass's own (Rails before_action semantics).
        def effective_chain(info, controllers, visited = Set.new)
          return [] if visited.include?(info.class_name)
          visited << info.class_name

          parent = controllers[info.superclass_name]
          parent_chain = parent ? effective_chain(parent, controllers, visited) : []
          parent_chain + info.chain
        end

        def collect_skipped_scopes(controllers)
          controllers.each_value.flat_map { |info| info.skips.map { |s| s[:scope] } }.compact.to_set
        end

        # Walks up from the controller that sees the callback to the class
        # that defines the handler method.
        def defining_class(handler, info, controllers, visited = Set.new)
          return nil if visited.include?(info.class_name)
          visited << info.class_name

          return info.class_name if info.defs.include?(handler)

          parent = controllers[info.superclass_name]
          parent ? defining_class(handler, parent, controllers, visited) : nil
        end

        # Walks the superclass chain (within the app) looking for the
        # nearest guard. Chains that leave the app resolve to no guard.
        def effective_guard(info, controllers, visited = Set.new)
          return [nil, nil] if visited.include?(info.class_name)
          visited << info.class_name

          own = info.chain.find { |entry| entry[:scope] }
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
