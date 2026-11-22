# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # What each `self` handed to a call is, by the checker: the self type it
      # recorded for that call. Steep types a `self` node as the abstract
      # `self`, which says nothing outside its method; the call knows whether
      # it runs on an instance or on the class object (`singleton(::Base)` in a
      # class body, in `class << self` and in a `def self.`). Inside a body every
      # call of which is known, it is the selves those calls run it on.
      module CallSelves
        SENDS = %i[send csend].freeze
        DEFS = %i[def defs].freeze
        VALUE_WRAPPERS = %i[hash kwargs pair array splat kwsplat block_pass begin].freeze

        module_function

        # `{ expression_key => "singleton(Base)" }`, keyed as `all_expression_types` is.
        # `specializations`: where the selves every call of a `def` runs it on are recorded.
        def types(typing, specializations:, factory:)
          result = {}
          walk(typing.source.node, typing, recorded_selves(typing, specializations, factory), nil) do |node, type|
            loc = node.loc.expression
            key = SteepBridge.expression_key(loc.first_line, loc.column, loc.last_line, loc.last_column)
            result[key] = TypeFormatter.format_type(type)
          end
          result
        end

        def recorded_selves(typing, specializations, factory)
          keys = {}.compare_by_identity
          Steep::Specializations::Collector.definitions(typing.source).each { |key, node| keys[node] = key }
          ->(def_node) { (key = keys[def_node]) && specializations.selves(key, factory: factory) }
        end

        def walk(node, typing, selves, called_on, &)
          return unless node.is_a?(Parser::AST::Node)

          called_on = selves.call(node) if DEFS.include?(node.type)
          if SENDS.include?(node.type) && (type = self_type(typing, node, called_on))
            receiver, _name, *arguments = node.children
            [receiver, *arguments].each { |value| each_self(value) { |self_node| yield self_node, type } }
          end
          node.children.each { |child| walk(child, typing, selves, called_on, &) }
        end

        def self_type(typing, node, called_on)
          type = typing.self_type_of_call(node: node) or return nil
          called_on && !called_on.include?(type) ? Steep::AST::Types::Union.build(types: called_on) : type
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
