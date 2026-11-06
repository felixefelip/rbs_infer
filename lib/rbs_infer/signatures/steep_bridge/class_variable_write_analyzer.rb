# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # The class variables a class's code assigns, for its RBS: `{ "@@x" => "T" }`,
      # with `T` the union of what each assignment writes, nilable unless a class
      # body assigns it, the rule `self.@x` follows. One a superclass already
      # declares is that slot, so it is left to the superclass.
      class ClassVariableWriteAnalyzer
        def initialize(steep_bridge:)
          @steep_bridge = steep_bridge
        end

        # `{ owner => types }`, the class's own under `nil` and each nested
        # module's under its name.
        def by_owner(parsed, target_class:, owners:)
          return {} unless parsed&.source

          scopes = { nil => target_class }.merge(owners.to_h { |owner| [owner, "#{target_class}::#{owner}"] })
          scopes.transform_values { |scope| types(parsed.source, file: parsed.path, target_class: scope) }
        end

        private

        def types(source_code, file:, target_class:)
          typing = @steep_bridge.type_check(source_code, file:)
          node = typing&.source&.node or return {}

          Writes.new(typing, target_class).of(node).reject { |name, _| declared_above?(name, target_class) }
        end

        def declared_above?(name, target_class)
          type_name = RBS::TypeName.parse("::#{target_class.to_s.delete_prefix("::")}")
          builder = SteepEnvironment.definition_builder
          return false unless builder&.env&.module_class_entry(type_name)

          variable = builder.build_singleton(type_name).class_variables[name.to_sym]
          !variable.nil? && variable.declared_in != type_name
        rescue RBS::BaseError
          false
        end

        class Writes
          def initialize(typing, target_class)
            @typing = typing
            @target_class = target_class
            @dead = DeadBranches.new(typing)
            @sets = Hash.new { |sets, name| sets[name] = RbsInfer::Inference::IvarTypeSet.new }
            @initialized = Set.new
          end

          def of(root)
            walk(root, [], false)
            @sets.filter_map do |name, set|
              type = set.emit(force_nilable: !@initialized.include?(name))
              [name, type] if type
            end.to_h
          end

          private

          def walk(node, namespace, in_body)
            return unless node.is_a?(::Parser::AST::Node)

            name, value = assigned(node)
            in_scope = LexicalScope.class_scope_match?(namespace, @target_class)
            record(name.to_s, node, value, in_body) if value && in_scope
            inner, body = inside(node, namespace, in_body)
            node.children.each { |child| walk(child, inner, body) }
          end

          def assigned(node)
            case node.type
            when :cvasgn then node.children
            when :or_asgn, :and_asgn
              target, value = node.children
              [target.children[0], value] if target.type == :cvasgn
            end
          end

          def inside(node, namespace, in_body)
            case node.type
            when :class, :module then [LexicalScope.push_namespace(namespace, node), true]
            when :def, :defs then [namespace, false]
            else [namespace, in_body]
            end
          end

          def record(name, node, value, in_body)
            return if @dead.cover?(node)

            @initialized << name if in_body
            type = TypeFormatter.intrinsic_type_of(value, @typing) or return
            @sets[name].add(TypeFormatter.format_type(type))
          end
        end
      end
    end
  end
end
