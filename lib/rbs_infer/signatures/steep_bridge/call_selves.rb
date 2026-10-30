# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # What each `self` handed to a call is, by the checker: the self type it
      # recorded for that call. Steep types a `self` node as the abstract
      # `self`, which says nothing outside its method; the call knows whether
      # it runs on an instance or on the class object (`singleton(::Base)` in a
      # class body, in `class << self` and in a `def self.`).
      module CallSelves
        SENDS = %i[send csend].freeze
        VALUE_WRAPPERS = %i[hash kwargs pair array splat kwsplat block_pass begin].freeze

        module_function

        # `{ expression_key => "singleton(Base)" }`, keyed as `all_expression_types` is.
        def types(typing)
          result = {}
          walk(typing.source.node, typing) do |node, type|
            loc = node.loc.expression
            key = SteepBridge.expression_key(loc.first_line, loc.column, loc.last_line, loc.last_column)
            result[key] = TypeFormatter.format_type(type)
          end
          result
        end

        def walk(node, typing, &)
          return unless node.is_a?(Parser::AST::Node)

          if SENDS.include?(node.type) && (type = typing.self_type_of_call(node: node))
            receiver, _name, *arguments = node.children
            [receiver, *arguments].each { |value| each_self(value) { |self_node| yield self_node, type } }
          end
          node.children.each { |child| walk(child, typing, &) }
        end

        def each_self(node, &)
          return unless node.is_a?(Parser::AST::Node)
          return yield node if node.type == :self

          node.children.each { |child| each_self(child, &) } if VALUE_WRAPPERS.include?(node.type)
        end
      end
    end
  end
end
