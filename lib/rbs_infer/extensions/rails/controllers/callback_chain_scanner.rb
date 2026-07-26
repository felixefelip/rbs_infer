# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module Controllers
        # A `if:`/`unless:` option we cannot name (a lambda, say). The
        # pseudo-code models it as an opaque "may or may not run", so the link
        # proves nothing rather than inventing a fact.
        UNKNOWN_CONDITION = :__unknown__

        # One link of a controller's `before_action` chain, already resolved
        # against the class that will run it. `kind` is:
        #
        #   :handler — `before_action :set_post` (call the method)
        #   :block   — `before_action { @x = ... }` (inline the block body)
        #
        # `if_cond`/`unless_cond` hold the *predicate method name* of a
        # `if:`/`unless:` option, or `UNKNOWN_CONDITION`.
        Callback = Struct.new(
          :kind, :handler, :block_source, :only, :except, :if_cond, :unless_cond, :prepended,
          keyword_init: true
        ) do
          # True when this callback runs for `action` (`only:`/`except:`).
          def runs_for?(action)
            return false if only && !only.include?(action)
            return false if except&.include?(action)

            true
          end
        end

        # A controller class or a concern module, as read from source. Concerns
        # carry only the callbacks their `included do … end` block registers;
        # the `include` site splices them into the includer's chain in place.
        #
        # `render_targets` holds every explicit `render` view target found in the
        # class's method bodies, each tagged by form:
        #
        #   `render :new`         => `[:symbol, "new"]`   (controller-relative)
        #   `render "posts/new"`  => `[:string, "posts/new"]` (absolute view path)
        #   `render "new"`        => `[:string, "new"]`   (controller-relative)
        #
        # so the pseudo-code can model that render as a call into the view's
        # compiled body — resolving the ERB class relative to this controller for
        # a symbol/bare string, or by absolute path for a `"dir/view"` string
        # (which may name ANOTHER controller's view).
        Unit = Struct.new(
          :name, :superclass_name, :kind, :actions, :body, :render_targets, keyword_init: true
        )

        # `include SomeConcern` inside a class body, kept in declaration order
        # alongside the callbacks so the chain can be spliced at the right spot
        # (Rails registers a concern's `included do` callbacks at include time).
        Include = Struct.new(:name, keyword_init: true)

        # A `skip_before_action :handler` declaration.
        Skip = Struct.new(:handler, :only, :except, keyword_init: true)

        # Reads `app/controllers/**/*.rb` and answers, per controller action,
        # WHICH before_action links run and in what order — the input for the
        # pseudo-code runner (felixefelip/rbs_infer#81).
        #
        # Rails semantics modelled here:
        #
        #   * ancestors' callbacks run before the subclass's own;
        #   * `include Concern` splices the concern's `included do` callbacks
        #     at the point of inclusion;
        #   * `prepend_before_action` goes to the front of the chain;
        #   * `only:`/`except:` filter which actions a link runs for;
        #   * `skip_before_action` removes a link (honouring its own
        #     `only:`/`except:`).
        #
        # It answers WHAT RUNS, never WHAT IS PROVEN — the proof is the Steep
        # fork's job, read off the pseudo-code bodies. That split is the whole
        # point of the pseudo-code approach: no guard shape is pattern-matched
        # here.
        class CallbackChainScanner
          CALLBACK_MACROS = %i[before_action prepend_before_action].freeze

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # Controller class names that define at least one action, sorted.
          # `app/controllers` also holds classes that are NOT controllers
          # (framework reopens, plain helpers); the `Controller` suffix is the
          # Rails convention that separates them, and a non-controller has no
          # request flow to model.
          def controllers
            units.values
                 .select { |u| u.kind == :class && u.name.end_with?("Controller") && u.actions.any? }
                 .map(&:name).sort
          end

          # Public actions of `class_name`, in source order.
          def actions_for(class_name)
            units[class_name]&.actions || []
          end

          # The `[form, value]` render targets of `class_name`'s method bodies
          # (see `Unit`), de-duplicated and sorted for a stable emission. Drives
          # the per-controller `render` override — an action that renders a
          # non-convention view (`create` failing to `render :new`, or a foreign
          # `render "posts/new"`).
          def render_targets_for(class_name)
            (units[class_name]&.render_targets || []).uniq.sort
          end

          # The effective before_action chain of `class_name#action`, in run
          # order. Skips already applied.
          def chain_for(class_name, action)
            unit = units[class_name]
            return [] unless unit

            callbacks = effective_body(unit)
            skips = effective_skips(unit)

            callbacks
              .select { |cb| cb.runs_for?(action) }
              .reject { |cb| skipped?(cb, skips, action) }
          end

          private

          def skipped?(callback, skips, action)
            return false unless callback.kind == :handler

            skips.any? { |s| s.handler == callback.handler && applies_skip?(s, action) }
          end

          def applies_skip?(skip, action)
            return skip.only.include?(action) if skip.only
            return !skip.except.include?(action) if skip.except

            true
          end

          # Ancestors first, then own body — with `include`s spliced in place
          # and `prepend_before_action` hoisted to the front.
          def effective_body(unit, visited = Set.new)
            return [] if visited.include?(unit.name)

            visited << unit.name

            parent = units[unit.superclass_name]
            inherited = parent ? effective_body(parent, visited) : []

            own = unit.body.flat_map do |entry|
              case entry
              when Include then included_callbacks(entry.name, visited)
              when Callback then [entry]
              else []
              end
            end

            prepended, appended = own.partition(&:prepended)
            prepended + inherited + appended
          end

          def included_callbacks(concern_name, visited)
            concern = units[concern_name]
            return [] unless concern && concern.kind == :module

            effective_body(concern, visited)
          end

          # Skips declared anywhere in the class's own chain of ancestors and
          # the concerns it includes.
          def effective_skips(unit, visited = Set.new)
            return [] if visited.include?(unit.name)

            visited << unit.name

            parent = units[unit.superclass_name]
            inherited = parent ? effective_skips(parent, visited) : []
            from_concerns = unit.body.grep(Include).flat_map do |inc|
              concern = units[inc.name]
              concern ? effective_skips(concern, visited) : []
            end

            inherited + from_concerns + unit.body.grep(Skip)
          end

          def units
            @units ||= Dir.glob(File.join(@app_dir, "app/controllers/**/*.rb")).sort.each_with_object({}) do |path, acc|
              source = File.read(path)
              result = Prism.parse(source)
              next unless result.success?

              parse_units(result.value, source).each { |unit| acc[unit.name] = unit }
            end
          end

          def parse_units(root, source)
            nodes = RbsInfer::Analyzer.find_all_nodes(root) do |n|
              n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)
            end

            nodes.filter_map do |node|
              name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)&.delete_prefix("::")
              next unless name

              if node.is_a?(Prism::ClassNode)
                class_unit(node, name, source)
              else
                concern_unit(node, name, source)
              end
            end
          end

          def class_unit(node, name, source)
            actions = []
            body = []
            render_targets = []
            visibility = :public

            statements(node.body).each do |stmt|
              case stmt
              when Prism::DefNode
                next unless stmt.receiver.nil?

                # `render :view` can sit in any instance method (an action or a
                # private helper it delegates to), so collect from every def.
                render_targets.concat(render_targets_of(stmt))

                # A routable action is a plain identifier; `foo?`/`foo!`/`foo=`
                # are helpers that happen to be public.
                next unless stmt.name.to_s.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

                actions << stmt.name.to_s if visibility == :public
              when Prism::CallNode
                if %i[private protected].include?(stmt.name) && stmt.arguments.nil?
                  visibility = stmt.name
                else
                  body.concat(body_entries(stmt, source))
                end
              end
            end

            Unit.new(
              name: name,
              superclass_name: node.superclass && RbsInfer::Analyzer.extract_constant_path(node.superclass)&.delete_prefix("::"),
              kind: :class, actions: actions, body: body, render_targets: render_targets
            )
          end

          # The `[form, value]` targets of every `render` inside a def body,
          # found at any depth (a `render :new` in the `else` of `if @post.save`).
          # Only a leading positional symbol/string is recognized — `render
          # action: …`, `render template: …`, `render partial: …` are future work.
          def render_targets_of(def_node)
            RbsInfer::Analyzer.find_all_nodes(def_node) do |n|
              n.is_a?(Prism::CallNode) && n.name == :render && n.receiver.nil?
            end.filter_map { |call| render_target_arg(call) }
          end

          def render_target_arg(call)
            first = call.arguments&.arguments&.first
            case first
            when Prism::SymbolNode then [:symbol, first.value.to_s]
            when Prism::StringNode then [:string, first.unescaped]
            end
          end

          # A concern contributes only what its `included do … end` block
          # registers — its plain method defs are just methods, reachable as
          # self-sends from the includer.
          def concern_unit(node, name, source)
            body = statements(node.body).flat_map do |stmt|
              next [] unless stmt.is_a?(Prism::CallNode) && stmt.name == :included && stmt.block

              statements(stmt.block.body).flat_map do |inner|
                inner.is_a?(Prism::CallNode) ? body_entries(inner, source) : []
              end
            end

            Unit.new(name: name, superclass_name: nil, kind: :module, actions: [], body: body, render_targets: [])
          end

          def body_entries(call, source)
            case call.name
            when :include
              constant_args(call).map { |const| Include.new(name: const) }
            when :skip_before_action
              skips(call)
            when *CALLBACK_MACROS
              callbacks(call, source, prepend: call.name == :prepend_before_action)
            else
              []
            end
          end

          def callbacks(call, source, prepend:)
            options = options_of(call, source)
            handlers = symbol_args(call)

            entries = handlers.map do |handler|
              Callback.new(kind: :handler, handler: handler, prepended: prepend, **options)
            end

            if call.block.is_a?(Prism::BlockNode) && (block = block_source(call.block, source))
              entries << Callback.new(kind: :block, block_source: block, prepended: prepend, **options)
            end

            entries
          end

          def skips(call)
            options = options_of(call, nil)
            symbol_args(call).map do |handler|
              Skip.new(handler: handler, only: options[:only], except: options[:except])
            end
          end

          # Source text of a `before_action do … end` block body, so the
          # runner can inline it verbatim (the block runs in the controller's
          # instance context, so its body is valid there as-is).
          def block_source(block, source)
            body = block.body
            return nil unless body

            source[body.location.start_offset...body.location.end_offset]
          end

          def options_of(call, source)
            hash = call.arguments&.arguments&.grep(Prism::KeywordHashNode)&.first
            return { only: nil, except: nil, if_cond: nil, unless_cond: nil } unless hash

            opts = { only: nil, except: nil, if_cond: nil, unless_cond: nil }

            hash.elements.each do |elem|
              next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)

              case elem.key.value.to_s
              when "only" then opts[:only] = symbol_list(elem.value)
              when "except" then opts[:except] = symbol_list(elem.value)
              when "if" then opts[:if_cond] = predicate(elem.value, source)
              when "unless" then opts[:unless_cond] = predicate(elem.value, source)
              end
            end

            opts
          end

          # A `if:`/`unless:` condition, rendered as a Ruby expression the
          # pseudo-code can splice into an `if`:
          #
          #   if: :authenticated?     => "authenticated?"  (a self-send)
          #   if: -> { params[:id] }  => "(params[:id])"   (Rails instance_execs the
          #                                                 lambda on the controller,
          #                                                 so its body is valid as-is)
          #
          # Anything else — a lambda taking the controller as an argument, a proc
          # held in a variable, a multi-statement body — cannot be spliced and
          # becomes UNKNOWN_CONDITION.
          def predicate(node, source)
            case node
            when Prism::SymbolNode then node.value.to_s
            when Prism::StringNode then node.unescaped
            when Prism::LambdaNode then lambda_condition(node, source)
            else UNKNOWN_CONDITION
            end
          end

          # Source of a zero-arity, single-statement lambda body.
          def lambda_condition(node, source)
            return UNKNOWN_CONDITION if source.nil? || node.parameters

            body = statements(node.body)
            return UNKNOWN_CONDITION unless body.size == 1

            "(#{source[body.first.location.start_offset...body.first.location.end_offset]})"
          end

          def symbol_args(call)
            (call.arguments&.arguments || []).grep(Prism::SymbolNode).map { |s| s.value.to_s }
          end

          def constant_args(call)
            (call.arguments&.arguments || []).filter_map do |arg|
              RbsInfer::Analyzer.extract_constant_path(arg)&.delete_prefix("::") if constant?(arg)
            end
          end

          def constant?(node)
            node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
          end

          def symbol_list(node)
            nodes = node.is_a?(Prism::ArrayNode) ? node.elements : [node]
            nodes.filter_map { |n| n.value.to_s if n.is_a?(Prism::SymbolNode) }
          end

          def statements(body)
            case body
            when Prism::StatementsNode then body.body
            when nil then []
            else [body]
            end
          end
        end
      end
    end
  end
end
