# frozen_string_literal: true

require "prism"

module RbsInfer
  module Inference
    # A `send` written with a LITERAL name is a call to that method, and this is the one
    # place that knows how to read it (felixefelip/rbs_infer#205).
    #
    # `recv.send(:stamp, "post")` passes `"post"` to `stamp`'s first parameter as surely as
    # `recv.stamp("post")` does. Nothing about it is undecidable: the name is right there.
    # The only thing the spelling adds is that it reaches past `private` — which is why a
    # real app reaches for it, and why `stamp`'s parameter used to have no call site at all.
    #
    # PLAIN RUBY, so this belongs in the core: `send` exists without any gem, which is the
    # litmus in docs/engineering/keep-core-framework-agnostic.md. Sibling in spirit to
    # `ClassEvalExpander`, which reads `class_eval` as a reopen for the same reason.
    #
    # The answer is a real `Prism::CallNode` — the same node with the method's name and
    # without the name literal — so every reader downstream (positional mapping, keyword
    # args, splat folding, blocks, established ivars) works on it untouched, and none of
    # them learns anything about `send`.
    module SendCall
      # One dispatch, three spellings. `__send__` is the one a defensive library uses,
      # precisely because `send` can be overridden.
      SPELLINGS = %i[send __send__ public_send].freeze

      # The call the node stands for, or nil when it is not that shape. Two ways it is not:
      # the name is computed (`send(name)`, `send(:"a#{b}")`), which nothing static decides,
      # and the node is not a `send` at all.
      #
      # Visibility is deliberately not modelled. `public_send` reaching a private method is
      # a runtime `NoMethodError`, and the checker is what reports it
      # (felixefelip/steep#137); here it is still a call site, and reading the argument it
      # passes is right either way.
      def self.desugar(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless SPELLINGS.include?(node.name)

        arguments = node.arguments or return nil
        name = literal_name(arguments.arguments.first) or return nil

        node.copy(
          name: name,
          arguments: arguments.copy(arguments: arguments.arguments.drop(1))
        )
      end

      # The method name an argument spells, when it spells one at all. A symbol or string
      # literal names a method; an interpolated symbol (`:"a#{b}"` parses as a
      # `InterpolatedSymbolNode`), a variable and a constant do not.
      def self.literal_name(node)
        case node
        when Prism::SymbolNode then node.unescaped&.to_sym
        when Prism::StringNode then node.unescaped&.to_sym
        end
      end
    end
  end
end
