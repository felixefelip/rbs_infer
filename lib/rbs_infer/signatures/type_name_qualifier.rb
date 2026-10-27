# frozen_string_literal: true

module RbsInfer
  module Signatures
    # Type names travel through the pipeline as absolute names written without
    # the leading `::`. RBS reads a bare name relative to the declaration it sits
    # in, so `Hash` emitted inside `module Concurrent` means `Concurrent::Hash`
    # wherever that class exists. This writes `::` in front of each name whose
    # relative reading lands on a different declaration, following RBS's own
    # lookup (`RBS::Resolver::TypeNameResolver`): innermost namespace outwards,
    # the superclass from outside its class.
    class TypeNameQualifier
      def self.apply(rbs, declared:)
        new(rbs, declared: declared).apply
      end

      def initialize(rbs, declared:)
        @rbs = rbs
        @declared = declared
      end

      def apply
        _, _, decls = RBS::Parser.parse_signature(@rbs)
        @own = Set.new
        decls.each { |decl| collect_own(decl, "") }
        shadowed_positions(decls).reverse.each_with_object(@rbs.dup) { |pos, out| out.insert(pos, "::") }
      rescue RBS::ParsingError
        @rbs
      end

      private

      def shadowed_positions(decls)
        decls.flat_map { |decl| names_in_declaration(decl, []) }
             .filter_map { |name, location, context| location.start_pos if shadowed?(name, context) }
             .uniq.sort
      end

      def collect_own(decl, outer)
        return unless decl.respond_to?(:members) && decl.respond_to?(:name)

        full = join(outer, decl.name.to_s)
        @own << full
        decl.members.each { |member| collect_own(member, full) }
      end

      def names_in_declaration(decl, outer)
        case decl
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
          inner = [join(outer.first || "", decl.name.to_s), *outer]
          own = superclass_names(decl, outer) + decl.type_params.flat_map { |param| type_params_names(param, inner) }
          own + decl.members.flat_map { |member| names_in_member(member, inner) }
        else
          []
        end
      end

      def superclass_names(decl, outer)
        return [] unless decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class

        super_class = decl.super_class
        [[super_class.name, super_class.location[:name], outer]] +
          super_class.args.flat_map { |type| names_in_type(type, outer) }
      end

      def type_params_names(param, context)
        [param.upper_bound, param.default_type].compact.flat_map { |type| names_in_type(type, context) }
      end

      def names_in_member(member, context)
        case member
        when RBS::AST::Declarations::Base
          names_in_declaration(member, context)
        when RBS::AST::Members::MethodDefinition
          member.overloads.flat_map { |overload| method_type_names(overload.method_type, context) }
        when RBS::AST::Members::Mixin
          [[member.name, member.location[:name], context], *types_names(member.args, context)]
        else
          member.respond_to?(:type) ? types_names([member.type].compact, context) : []
        end
      end

      def method_type_names(method_type, context)
        method_type.type_params.flat_map { |param| type_params_names(param, context) } +
          types_names(method_type.each_type, context)
      end

      def types_names(types, context) = types.flat_map { |type| names_in_type(type, context) }

      def names_in_type(type, context)
        own = case type
              when RBS::Types::ClassInstance, RBS::Types::ClassSingleton
                type.location ? [[type.name, type.location[:name], context]] : []
              else
                []
              end
        own + type.each_type.flat_map { |child| names_in_type(child, context) }
      end

      def shadowed?(type_name, context)
        return false if type_name.absolute?

        name = type_name.to_s
        resolved = resolve(name, context)
        resolved && resolved != name && declared?(name)
      end

      def resolve(name, context)
        head, *rest = name.split("::")
        [*context, ""].each do |prefix|
          candidate = join(prefix, head)
          return [candidate, *rest].join("::") if declared?(candidate)
        end
        nil
      end

      def declared?(name) = @own.include?(name) || @declared.call(name)

      def join(prefix, name) = prefix.empty? ? name : "#{prefix}::#{name}"
    end
  end
end
