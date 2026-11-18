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

        # The stores the class makes into its hashes, recorded once per checked
        # file; the block answers which nodes are the class's own.
        def self.recorded(typing, target_class:, singleton:, constructor_bindings:, literal_methods:)
          memo = (@recorded ||= ObjectSpace::WeakKeyMap.new)[typing] ||= {}
          memo[[target_class, singleton]] ||=
            new(typing.source.node, target_class:, singleton:, constructor_bindings:,
                                    literal_methods:).tap do |elements|
              elements.record_all(typing, yield(elements))
            end
        end

        def initialize(source_node, target_class:, singleton:, constructor_bindings:, literal_methods:)
          @constructor_bindings = constructor_bindings
          @literal_methods = literal_methods
          @holders = holders(source_node, target_class, singleton)
          @elements = Hash.new { |h, k| h[k] = [RbsInfer::Inference::IvarTypeSet.new, RbsInfer::Inference::IvarTypeSet.new] }
          @stores = Hash.new(0)
          @keyed = Hash.new { |h, k| h[k] = {} }
        end

        # `hash[key] = value`, `hash.store(key, value)`, or `hash[key] ||= value`.
        def store?(node)
          parts = stored(node) or return false
          receiver, method_name, *args = parts
          STORES.include?(method_name) && args.size == 2 && !held_ivar(receiver).nil?
        end

        def record(node, typing)
          receiver, _, *args = stored(node)
          return if store_on_another_class?(node.type == :or_asgn ? node.children[0] : node, typing)

          ivar = held_ivar(receiver)
          @stores[ivar] += 1
          args.zip(@elements[ivar]).each do |arg, set|
            type = TypeFormatter.intrinsic_type_of(arg, typing)
            set.add(TypeFormatter.format_type(type)) if type
          end
          record_keyed(ivar, *args, typing)
        end

        def record_all(typing, in_scope)
          dead = DeadBranches.new(typing)
          typing.each_typing do |node, _type|
            record(node, typing) if in_scope.include?(node.object_id) && !dead.cover?(node) && store?(node)
          end
        end

        # A record the ivar is given, with the keys this class stores into it
        # added as optional fields: the hash holds them once a store has run.
        # A store made elsewhere is rejected by the checker against the record.
        def widen(ivar, type)
          return type if @keyed[ivar].empty?

          members = RbsInfer::Inference::TypeUnion.flatten_union(type)
          RbsInfer::Inference::TypeUnion.of(members.map { |member| with_stored_keys(ivar, member) })
        end

        def hash_type(ivar)
          key, value = confined?(ivar) ? @elements[ivar].map { |set| set.emit || "untyped" } : %w[untyped untyped]
          "Hash[#{key}, #{value}]"
        end

        private

        def record_keyed(ivar, key, value, typing)
          type = TypeFormatter.intrinsic_type_of(value, typing) if key.is_a?(::Parser::AST::Node) && key.type == :sym
          return unless type

          (@keyed[ivar][key.children[0]] ||= RbsInfer::Inference::IvarTypeSet.new).add(TypeFormatter.format_type(type))
        end

        def with_stored_keys(ivar, member)
          record = parse_record(member) or return member
          added = @keyed[ivar].reject { |key, _| record.all_fields.key?(key) }
          added.empty? ? member : "{ #{(given_fields(record) + added_fields(added)).join(", ")} }"
        end

        def parse_record(member)
          parsed = RBS::Parser.parse_type(member)
          parsed if parsed.is_a?(RBS::Types::Record)
        rescue RBS::ParsingError
          nil
        end

        def given_fields(record)
          record.all_fields.map { |key, (type, required)| "#{"?" unless required}#{key}: #{type}" }
        end

        def added_fields(added) = added.map { |key, set| "?#{key}: #{set.emit || "untyped"}" }

        def confined?(ivar)
          names = [:"@#{ivar}", *@holders.filter_map { |name, held| name if held == ivar }]
          uses = names.flat_map { |name| @constructor_bindings.uses_of(name) }
          Steep::HashMutation.confined?(@literal_methods, uses) && stores_seen(names) == @stores[ivar]
        end

        def stores_seen(names)
          names.sum { |name| @constructor_bindings.uses_of(name).count { |use| STORES.include?(use.called) } }
        end

        def stored(node)
          return node.children if node.type == :send
          return unless node.type == :or_asgn && node.children[0].type == :send

          receiver, method_name, *keys = node.children[0].children
          [receiver, :[]=, *keys, node.children[1]] if method_name == :[]
        end

        def holders(source_node, target_class, singleton)
          return {} unless target_class

          scan = Steep::TypeInference::ConstructorBindingAnalyzer.scan(source_node,
                                                                       folded_evals: @constructor_bindings.folded_evals)
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
