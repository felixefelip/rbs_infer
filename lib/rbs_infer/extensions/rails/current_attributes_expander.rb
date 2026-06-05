# frozen_string_literal: true

require "prism"
require_relative "../../source_expanders"

module RbsInfer
  module Extensions
    module Rails
      # Desugars the `attribute :x` macros of ActiveSupport::CurrentAttributes
      # subclasses into plain-Ruby pseudo-code, so the existing inference
      # pipeline sees the accessors as ordinary defs
      # (felixefelip/rbs_infer#19).
      #
      # The pseudo-code exists only in memory during generation — it is
      # never loaded at runtime nor seen by the app's `steep check` (which
      # reads the real source + the generated RBS). The shape is the
      # simplest source that yields the right types, not a faithful
      # simulation of the runtime:
      #
      #   attribute :user
      #   # becomes:
      #   def user; @user; end
      #   def user=(value); @user = value; end
      #   def self.user; @user; end
      #   def self.user=(value); @user = value; end
      #
      # Both levels (instance and singleton) read/write the SAME ivar on
      # purpose: the type pool is unified, mirroring the shared
      # `@attributes` of the real CurrentAttributes.
      #
      # The per-request reset semantics expressed as code:
      # - without `default:` → `@user` is never assigned in `initialize`,
      #   so the existing definite-initialization rule emits `User?`.
      # - with `default:` → the expander emits
      #   `def initialize; @user = <expr>; end`, making the ivar
      #   non-nilable and adding the default as a type source.
      #
      # `set`/`with` (set is an alias of with) become defs with kwargs
      # that write the ivars directly, so call-sites like
      # `Current.set(user: u)` feed the same inference flow.
      module CurrentAttributesExpander
        SUPERCLASS_NAMES = [
          "ActiveSupport::CurrentAttributes",
          "::ActiveSupport::CurrentAttributes",
        ].freeze

        module_function

        # Returns the expanded source, or nil when there is nothing to
        # expand (the file defines no CurrentAttributes subclass with
        # `attribute` declarations).
        def expand(source)
          return nil unless source.include?("CurrentAttributes")

          result = Prism.parse(source)
          return nil unless result.success?

          replacements = []
          RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::ClassNode) }.each do |klass|
            next unless current_attributes_subclass?(klass)

            calls = attribute_calls_in(klass)
            next if calls.empty?

            attribute_names = calls.flat_map { |call| parse_attribute_call(source, call).first }
            overrides = accessor_overrides(klass, attribute_names)
            replacements.concat(build_replacements(source, calls, overrides))
            replacements.concat(super_replacements(source, overrides))
          end
          return nil if replacements.empty?

          apply_replacements(source, replacements)
        end

        def current_attributes_subclass?(klass)
          superclass = klass.superclass
          return false unless superclass

          SUPERCLASS_NAMES.include?(RbsInfer::Analyzer.extract_constant_path(superclass))
        end

        # Collects the `attribute ...` CallNodes at class-body level
        # (direct statements, no receiver). An `attribute` inside defs or
        # blocks is not the CurrentAttributes macro.
        def attribute_calls_in(klass)
          body = klass.body
          statements = case body
                       when Prism::StatementsNode then body.body
                       when nil then []
                       else [body]
                       end

          statements.select do |stmt|
            stmt.is_a?(Prism::CallNode) && stmt.name == :attribute && stmt.receiver.nil? && stmt.arguments
          end
        end

        # Builds the replacements for the `attribute` calls of ONE class.
        # Each call becomes the 4 accessors of its attributes; the last
        # call also gets `initialize` (when there is a `default:`) and
        # `set`/`with` with kwargs for all attributes of the class.
        #
        # Accessors the class body overrides (the Rails-guides pattern
        # `def user=(value); super; ...; end`) are NOT generated —
        # duplicating them would be invalid RBS. The override itself has
        # its `super` desugared by `super_replacements`.
        def build_replacements(source, calls, overrides)
          all_names = []
          defaults = {}

          parsed = calls.map do |call|
            names, call_defaults = parse_attribute_call(source, call)
            all_names.concat(names)
            defaults.merge!(call_defaults)
            [call, names]
          end

          parsed.map.with_index do |(call, names), idx|
            blocks = names.flat_map { |name| accessor_defs(name, overrides) }
            if idx == parsed.length - 1
              blocks.concat(initialize_def(defaults))
              blocks.concat(set_with_defs(all_names))
            end

            indent = " " * call.location.start_column
            {
              start: call.location.start_offset,
              end: call.location.end_offset,
              text: join_blocks(blocks, indent),
            }
          end
        end

        # Attribute accessor defs the class body declares itself (overrides
        # of the generated accessors), keyed [singleton?, method_name] →
        # DefNode. Other defs are NOT included — their `super` (if any)
        # has nothing to do with the generated accessors.
        def accessor_overrides(klass, attribute_names)
          accessor_names = attribute_names.flat_map { |n| [n, "#{n}="] }.to_set

          statements = case klass.body
                       when Prism::StatementsNode then klass.body.body
                       when nil then []
                       else [klass.body]
                       end

          statements.each_with_object({}) do |stmt, acc|
            next unless stmt.is_a?(Prism::DefNode)
            next unless accessor_names.include?(stmt.name.to_s)
            acc[[stmt.receiver.is_a?(Prism::SelfNode), stmt.name.to_s]] = stmt
          end
        end

        # At runtime `super` inside an accessor override dispatches to the
        # generated accessor (Rails defines them in an included
        # `generated_attribute_methods` module). In the expanded view the
        # generated accessor is the plain ivar read/write, so the `super`
        # desugars to exactly that:
        #
        #   def user=(value)        def user=(value)
        #     super(value)     →      @user = value
        #     ...                     ...
        def super_replacements(source, overrides)
          overrides.filter_map do |(_singleton, method_name), defn|
            attr = method_name.chomp("=")
            setter = method_name.end_with?("=")

            supers = RbsInfer::Analyzer.find_all_nodes(defn) do |n|
              n.is_a?(Prism::SuperNode) || n.is_a?(Prism::ForwardingSuperNode)
            end

            supers.map do |sup|
              text = if setter
                       "@#{attr} = #{super_argument_source(source, sup, defn)}"
                     else
                       "@#{attr}"
                     end
              { start: sup.location.start_offset, end: sup.location.end_offset, text: text }
            end
          end.flatten
        end

        # `super(expr)` → expr source; bare `super` forwards the def's
        # params — for the accessor signature that's the single value param.
        def super_argument_source(source, sup, defn)
          if sup.is_a?(Prism::SuperNode) && sup.arguments
            args = sup.arguments
            source.byteslice(args.location.start_offset, args.location.end_offset - args.location.start_offset)
          else
            first_param_name(defn) || "value"
          end
        end

        def first_param_name(defn)
          params = defn.parameters
          return nil unless params&.respond_to?(:requireds)

          first = params.requireds&.first
          first.respond_to?(:name) ? first.name.to_s : nil
        end

        # Each block is one multi-line def; blocks are separated by a
        # blank line. Only non-blank lines get the indent prefix, so the
        # output carries no trailing whitespace.
        def join_blocks(blocks, indent)
          blocks.map { |block| block.join("\n#{indent}") }.join("\n\n#{indent}")
        end

        # `attribute :user, :account, default: -> { ... }` →
        # [["user", "account"], { "user" => "<default source>", ... }]
        # The declared default applies to every attribute of the same call
        # (same behavior as ActiveSupport).
        def parse_attribute_call(source, call)
          names = []
          default_source = nil

          call.arguments.arguments.each do |arg|
            case arg
            when Prism::SymbolNode
              names << arg.value.to_s
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode)
                next unless elem.key.is_a?(Prism::SymbolNode) && elem.key.value.to_s == "default"

                default_source = default_expression_source(source, elem.value)
              end
            end
          end

          defaults = default_source ? names.to_h { |n| [n, default_source] } : {}
          [names, defaults]
        end

        # For lambdas/procs (`default: -> { User.new }`) the attribute
        # value is the RESULT of the callable — use the body. For any
        # other expression, the literal source.
        def default_expression_source(source, node)
          body = case node
                 when Prism::LambdaNode
                   node.body
                 when Prism::CallNode
                   node.block&.body if [:lambda, :proc].include?(node.name)
                 end

          expr = body || node
          slice = source.byteslice(expr.location.start_offset, expr.location.end_offset - expr.location.start_offset)
          multi_statement?(expr) ? "begin; #{slice}; end" : slice
        end

        def multi_statement?(node)
          node.is_a?(Prism::StatementsNode) && node.body.length > 1
        end

        def accessor_defs(name, overrides = {})
          defs = []
          defs << ["def #{name}", "  @#{name}", "end"] unless overrides.key?([false, name])
          defs << ["def #{name}=(value)", "  @#{name} = value", "end"] unless overrides.key?([false, "#{name}="])
          defs << ["def self.#{name}", "  @#{name}", "end"] unless overrides.key?([true, name])
          defs << ["def self.#{name}=(value)", "  @#{name} = value", "end"] unless overrides.key?([true, "#{name}="])
          defs
        end

        def initialize_def(defaults)
          return [] if defaults.empty?

          [
            ["def initialize"] +
              defaults.map { |name, expr| "  @#{name} = #{expr}" } +
              ["end"],
          ]
        end

        def set_with_defs(names)
          kwargs = names.map { |n| "#{n}: nil" }.join(", ")

          # `&block` keeps the signature call-compatible with real usage
          # (`Current.with(user: u) { ... }` restores attributes on exit).
          # The body ends in `block.call` because at runtime set/with
          # return the block's result — without it the inferred return
          # would be the assigned value, leaking into callers' types.
          ["set", "with"].map do |method|
            ["def self.#{method}(#{kwargs}, &block)"] +
              names.map { |n| "  @#{n} = #{n}" } +
              ["  block.call", "end"]
          end
        end

        # Applies the replacements back to front so earlier byte offsets
        # stay valid.
        def apply_replacements(source, replacements)
          out = source.dup
          replacements.sort_by { |r| -r[:start] }.each do |r|
            out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
          end
          out
        end
      end
    end
  end

  # Source-expansion plugin (registered by default: it is pure Prism —
  # no Rails at runtime — and self-gates on the superclass).
  SourceExpanders.register(Extensions::Rails::CurrentAttributesExpander)
end
