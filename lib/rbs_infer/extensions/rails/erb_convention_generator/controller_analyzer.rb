# frozen_string_literal: true

module RbsInfer
  module Extensions
    module Rails
      class ErbConventionGenerator
        module ControllerAnalyzer
          # Extract only the ivars relevant to a specific controller action,
          # narrowed to the contributions of the writers that actually run
          # for that action (the action method itself + `before_action`
          # handlers selected by `only:`/`except:`).
          #
          # Rationale: the controller's declared ivar type is the union of
          # *all* observed writes across *all* methods — e.g.,
          # `@company: ((Company & Validated) | Company)?`. Inside `show`
          # only `set_company` runs (via `before_action`), so the view
          # should see only `Company & Validated`, not the wide union.
          # Per-method types from `SteepBridge#ivar_write_types_per_method`
          # give us that granularity.
          #
          # **Cross-action rendering (felixefelip/rbs_infer#6)**: when a
          # view is rendered by 2+ actions (e.g., `edit.html.erb`
          # rendered by both `edit` and by `update`'s failure branch via
          # `render :edit`), the per-action narrowing is no longer safe
          # — it'd type the view by `edit`'s writers alone, missing
          # `update`'s contribution. In that case we fall back to the
          # controller's wide declared type (`controller_ivar_types`),
          # which is a sound super-set covering all rendering paths.
          def extract_action_ivars(controller_file, controller_class, action)
            per_method = controller_per_method_ivar_types(controller_file, controller_class)

            source = File.read(controller_file)
            tree = Prism.parse(source).value
            renderers = collect_view_renderers(tree, action.to_s)

            if renderers.size > 1
              return shared_view_ivar_types(controller_file, controller_class, tree, renderers, per_method)
            end

            return {} if per_method.empty?

            relevant = relevant_methods_for_action(tree, action)

            collected = Hash.new { |h, k| h[k] = RbsInfer::IvarTypeSet.new }
            relevant.each do |method_name|
              writes = per_method[method_name.to_s]
              next unless writes
              writes.each do |ivar, type|
                collected[ivar].add(type)
              end
            end

            result = {}
            collected.each do |ivar, type_set|
              # `force_nilable: false` — view templates render after the
              # action returned, so writers that did run produced
              # non-nil values. The full nilability picture lives in the
              # controller declaration; views narrow past it.
              emitted = type_set.emit(force_nilable: false)
              result[ivar] = emitted if emitted
            end
            result
          end

          # When a view is rendered by 2+ actions (e.g., `edit.html.erb`
          # rendered by both `edit` and `update`'s failure branch),
          # per-action narrowing can't capture all the contributions —
          # methods like `@x.update(...)` widen `@x` in their falsy
          # branch via Steep postcondition narrowing, and our
          # syntactic walker doesn't see that.
          #
          # Fallback: for every ivar **written by some method in the
          # rendering union**, emit the controller's *declared* type
          # (the wide union from `controller_ivar_types`, with outer
          # `?` stripped — same convention as the single-renderer
          # path). This is a sound super-set of every contributing
          # writer's type, covering the cases the per-method walker
          # misses.
          #
          # Ivars not touched by any rendering-action method (e.g.,
          # `@comments` set only in `show` when the view is
          # `edit.html.erb`) are excluded — bringing them into a view
          # that doesn't render them would be noise.
          def shared_view_ivar_types(controller_file, controller_class, tree, renderers, per_method)
            relevant_union = Set.new
            renderers.each do |renderer|
              relevant_union.merge(relevant_methods_for_action(tree, renderer))
            end

            touched_ivars = Set.new
            relevant_union.each do |method_name|
              writes = per_method[method_name.to_s]
              next unless writes
              touched_ivars.merge(writes.keys)
            end

            return {} if touched_ivars.empty?

            declared = controller_ivar_types(controller_file, controller_class)
            result = {}
            touched_ivars.each do |ivar|
              type = declared[ivar]
              result[ivar] = type if type
            end
            result
          end

          # Returns the set of action method names that render the
          # template `view_name`. Always includes the conventional
          # action (the action of the same name); adds any other
          # action whose body contains a `render` call that targets
          # this view (felixefelip/rbs_infer#6).
          #
          # Detected forms:
          # - `render :view_name`             (Symbol)
          # - `render "view_name"`            (String, NOT partial)
          # - `render template: "view_name"`  (or `"controller/view_name"`)
          # - `render action: :view_name`     (or `"view_name"`)
          #
          # Skipped (not template renders):
          # - `render partial: "..."` / `render "_underscored_name"` (partials)
          # - `render layout: "..."` (layout reference)
          # - `render plain:/json:/inline:/...` (non-template responses)
          def collect_view_renderers(tree, view_name)
            result = Set.new([view_name])

            each_def(tree) do |defn|
              action_name = defn.name.to_s
              next if action_name == view_name

              each_call(defn, :render) do |call|
                result << action_name if render_targets_template?(call, view_name)
              end
            end

            result
          end

          # Heuristic test: does `call` (a `render` invocation) target the
          # template `view_name`?
          def render_targets_template?(call, view_name)
            args = call.arguments&.arguments || []
            return false if args.empty?

            first = args[0]
            case first
            when Prism::SymbolNode
              return first.value.to_s == view_name
            when Prism::StringNode
              str = first.content
              # `_partial_name` strings are partials, not templates.
              return false if str.start_with?("_")
              # Match either bare "view_name" or "controller/view_name".
              return str == view_name || str.end_with?("/#{view_name}")
            end

            args.each do |arg|
              case arg
              when Prism::KeywordHashNode, Prism::HashNode
                arg.elements.each do |assoc|
                  next unless assoc.is_a?(Prism::AssocNode)
                  next unless assoc.key.is_a?(Prism::SymbolNode)

                  case assoc.key.value
                  when "partial"
                    # `partial:` is set → it's a partial render, not template.
                    return false
                  when "template"
                    value = case assoc.value
                            when Prism::StringNode then assoc.value.content
                            when Prism::SymbolNode then assoc.value.value.to_s
                            end
                    return true if value && (value == view_name || value.end_with?("/#{view_name}"))
                  when "action"
                    value = case assoc.value
                            when Prism::SymbolNode then assoc.value.value.to_s
                            when Prism::StringNode then assoc.value.content
                            end
                    return true if value == view_name
                  end
                end
              end
            end

            false
          end

          # Returns `{ method_name => { ivar_name => type } }` for the
          # controller class, cached. The keys are method names as
          # strings (matching `relevant_methods_for_action`'s output).
          def controller_per_method_ivar_types(controller_file, controller_class)
            @controller_per_method_ivar_cache ||= {}
            return @controller_per_method_ivar_cache[controller_class] if @controller_per_method_ivar_cache.key?(controller_class)

            source = File.read(controller_file)
            bridge = controller_steep_bridge
            @controller_per_method_ivar_cache[controller_class] = bridge.ivar_write_types_per_method(source)
          end

          def controller_steep_bridge
            @controller_steep_bridge ||= RbsInfer::Signatures::SteepBridge.new
          end

          # Generate controller RBS via Analyzer and extract ivar types (cached).
          #
          # Strips an outer trailing `?` from the ivar type. Rationale: in
          # the Rails request lifecycle a view template only runs after
          # the controller action returned, so an ivar that's nilable at
          # the *controller declaration* level (`@x: T?`) is in practice
          # always set by the time the view reads it. Keeping the `?`
          # here would force every `<%= @x.foo %>` to be flagged as a
          # NoMethod against nil. We keep inner-union nilability (e.g.
          # `T1 | nil` semantically inside a union) but only because the
          # outer-`?` form is what the rbs_infer ivar inferrer emits by
          # default (felixefelip/rbs_infer#4).
          def controller_ivar_types(controller_file, controller_class)
            @controller_ivar_cache ||= {}
            return @controller_ivar_cache[controller_class] if @controller_ivar_cache.key?(controller_class)

            rbs = controller_rbs(controller_file, controller_class)

            ivars = {}
            rbs&.each_line do |line|
              m = line.strip.match(/\A@(\w+): (.+)\z/)
              ivars[m[1]] = unwrap_outer_nilable(m[2]) if m
            end

            @controller_ivar_cache[controller_class] = ivars
          end

          # Removes a single trailing `?` and balanced wrapping parens.
          # `T?` → `T`. `(T1 | T2)?` → `T1 | T2`. `T` stays `T`.
          def unwrap_outer_nilable(type_str)
            return type_str unless type_str.end_with?("?")
            stripped = type_str.chomp("?")
            if stripped.start_with?("(") && stripped.end_with?(")") && balanced_outer_parens?(stripped)
              stripped[1..-2]
            else
              stripped
            end
          end

          def balanced_outer_parens?(str)
            return false unless str.start_with?("(") && str.end_with?(")")
            depth = 0
            str.each_char.with_index do |c, i|
              depth += 1 if c == "("
              depth -= 1 if c == ")"
              # If depth hits 0 before the very last char, the outer
              # parens are NOT a single balanced wrap (e.g. `(A) | (B)`).
              return false if depth.zero? && i < str.length - 1
            end
            depth.zero?
          end

          # Generate controller RBS (cached, shared with controller_ivar_types).
          def controller_rbs(controller_file, controller_class)
            @controller_rbs_cache ||= {}
            return @controller_rbs_cache[controller_class] if @controller_rbs_cache.key?(controller_class)

            @controller_rbs_cache[controller_class] = RbsInfer::Analyzer.new(
              target_class: controller_class,
              target_file: controller_file,
              source_files: @source_files
            ).generate_rbs
          end

          def detect_helpers(view_info)
            helpers = []

            if view_info
              helper_name = view_info[:controller_class].sub(/Controller\z/, "Helper")
              helper_path = "app/helpers/#{view_info[:controller_name]}_helper.rb"
              helpers << helper_name if File.exist?(File.join(@app_dir, helper_path))
            end

            # ActionViewContext (generated by rails_custom) bundles ActionView::Helpers,
            # _RbsRailsPathHelpers, ApplicationHelper, Kaminari::Helpers::HelperMethods,
            # and ApplicationController helper_methods.
            helpers << "ActionViewContext"

            helpers
          end

          # Collect helper_method declarations from controllers.
          # Returns a hash { method_name => type_signature }.
          def collect_helper_methods(view_info)
            methods = {}

            # ApplicationController helper_methods are now in the generated ActionViewContext
            # (rails_custom generator). Only check the specific controller here.
            if view_info
              app_ctrl = File.join(@app_dir, "app/controllers/application_controller.rb")
              ctrl_file = find_controller_file(view_info[:controller_name])
              if ctrl_file && ctrl_file != app_ctrl
                methods.merge!(extract_helper_method_signatures(ctrl_file, view_info[:controller_class]))
              end
            end

            methods
          end

          # Parse a controller file for `helper_method` declarations and
          # extract the method signatures from its generated RBS.
          def extract_helper_method_signatures(controller_file, controller_class)
            source = File.read(controller_file)
            tree = Prism.parse(source).value

            # Collect helper_method names
            names = Set.new
            each_call(tree, :helper_method) do |call|
              call.arguments&.arguments&.each do |arg|
                names << arg.value if arg.is_a?(Prism::SymbolNode)
              end
            end
            return {} if names.empty?

            # Get method signatures from controller RBS
            rbs = controller_rbs(controller_file, controller_class)
            return {} unless rbs

            signatures = {}
            rbs.each_line do |line|
              stripped = line.strip
              if (m = stripped.match(/\Adef (\w+[?!]?): (.+)\z/))
                signatures[m[1]] = m[2] if names.include?(m[1])
              end
            end
            signatures
          end

          private

          # Map ivar names to the set of methods that write them.
          def map_ivars_to_methods(tree)
            map = Hash.new { |h, k| h[k] = Set.new }
            each_def(tree) do |defn|
              method_name = defn.name.to_s
              each_ivar_write(defn) { |ivar_name| map[ivar_name] << method_name }
            end
            map
          end

          def each_def(node, &block)
            yield node if node.is_a?(Prism::DefNode)
            node.compact_child_nodes.each { |child| each_def(child, &block) }
          end

          def each_ivar_write(node, &block)
            case node
            when Prism::InstanceVariableWriteNode,
                 Prism::InstanceVariableOrWriteNode,
                 Prism::InstanceVariableAndWriteNode,
                 Prism::InstanceVariableOperatorWriteNode
              yield node.name.to_s.sub(/\A@/, "")
            end
            node.compact_child_nodes.each { |child| each_ivar_write(child, &block) }
          end

          # Compute the set of methods relevant to a given action:
          # the action itself + before_action callbacks that apply.
          def relevant_methods_for_action(tree, action)
            methods = Set.new([action])

            each_call(tree, :before_action) do |call|
              callback = extract_callback_name(call)
              next unless callback

              only = extract_action_filter(call, "only")
              except = extract_action_filter(call, "except")

              applies = if only
                          only.include?(action)
                        elsif except
                          !except.include?(action)
                        else
                          true
                        end

              methods << callback if applies
            end

            methods
          end

          def each_call(node, method_name, &block)
            yield node if node.is_a?(Prism::CallNode) && node.name == method_name
            node.compact_child_nodes.each { |child| each_call(child, method_name, &block) }
          end

          def extract_callback_name(call)
            arg = call.arguments&.arguments&.first
            arg.is_a?(Prism::SymbolNode) ? arg.value : nil
          end

          def extract_action_filter(call, key)
            call.arguments&.arguments&.each do |arg|
              next unless arg.is_a?(Prism::KeywordHashNode)

              arg.elements.each do |assoc|
                next unless assoc.is_a?(Prism::AssocNode)
                next unless assoc.key.is_a?(Prism::SymbolNode) && assoc.key.value == key

                return extract_symbol_list(assoc.value)
              end
            end
            nil
          end

          def extract_symbol_list(node)
            case node
            when Prism::ArrayNode
              node.elements.filter_map { |e| e.is_a?(Prism::SymbolNode) ? e.value : nil }
            when Prism::SymbolNode
              [node.value]
            end
          end
        end
      end
    end
  end
end
