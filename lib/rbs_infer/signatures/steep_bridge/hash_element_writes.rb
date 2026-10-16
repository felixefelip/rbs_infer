# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # The element types of the empty `{}` an ivar is given, from the stores made
      # into that object: on the ivar itself, or through a method of the class
      # whose body answers it (`@x ||= {}`, `@x`). Only for a hash the project
      # only reads or stores into (`Steep::HashMutation.confined?`), and whose
      # every store is one made here.
      class HashElementWrites
        STORES = %i[[]= store].freeze

        def initialize(source_node, target_class:, singleton:, constructor_bindings:, literal_methods:)
          @constructor_bindings = constructor_bindings
          @literal_methods = literal_methods
          @holders = holders(source_node, target_class, singleton)
          @elements = Hash.new { |h, k| h[k] = [RbsInfer::Inference::IvarTypeSet.new, RbsInfer::Inference::IvarTypeSet.new] }
          @stores = Hash.new(0)
        end

        def store?(node)
          receiver, method_name, *args = node.children
          STORES.include?(method_name) && args.size == 2 && !held_ivar(receiver).nil?
        end

        def record(node, typing)
          return if store_on_another_class?(node, typing)

          receiver, _, *args = node.children
          ivar = held_ivar(receiver)
          @stores[ivar] += 1
          args.zip(@elements[ivar]).each do |arg, set|
            type = TypeFormatter.intrinsic_type_of(arg, typing)
            set.add(TypeFormatter.format_type(type)) if type
          end
        end

        def hash_type(ivar)
          key, value = confined?(ivar) ? @elements[ivar].map { |set| set.emit || "untyped" } : %w[untyped untyped]
          "Hash[#{key}, #{value}]"
        end

        private

        def confined?(ivar)
          names = [:"@#{ivar}", *@holders.filter_map { |name, held| name if held == ivar }]
          Steep::HashMutation.confined?(@constructor_bindings, @literal_methods, names) &&
            stores_seen(names) == @stores[ivar]
        end

        def stores_seen(names)
          names.sum { |name| @constructor_bindings.uses_of(name).count { |use| STORES.include?(use.called) } }
        end

        def holders(source_node, target_class, singleton)
          return {} unless target_class

          scan = Steep::TypeInference::ConstructorBindingAnalyzer.scan(source_node)
          methods = (singleton ? scan.singleton_methods : scan.methods)[target_class.delete_prefix("::")] || {}
          methods.filter_map do |name, bodies|
            ivar = held_by(bodies)
            [name, ivar.to_s.delete_prefix("@")] if ivar
          end.to_h
        end

        def held_by(bodies)
          body = bodies.first if bodies.size == 1
          body && (body.memoizes || body.returns)
        end

        def held_ivar(receiver)
          return unless receiver.is_a?(::Parser::AST::Node)

          case receiver.type
          when :ivar
            receiver.children[0].to_s.delete_prefix("@")
          when :send
            self_receiver, name, *args = receiver.children
            @holders[name] if args.empty? && (self_receiver.nil? || self_receiver.type == :self)
          end
        end

        # An untyped receiver is still the object the ivar was given; only a store
        # Steep resolved to another class's method is not one on that hash.
        def store_on_another_class?(node, typing)
          call = typing.call_of(node: node)
          return false unless call.respond_to?(:method_decls)

          call.method_decls.any? { |decl| decl.method_name.type_name.to_s != "::Hash" }
        rescue Steep::Typing::UnknownNodeError
          false
        end
      end
    end
  end
end
