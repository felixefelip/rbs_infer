# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # How a signature's type relates to the one Steep gives a body, asked of
      # Steep's own subtyping so the answer cannot drift from its diagnostics.
      module TypeRelations
        # Whether a body typed `value` satisfies a declaration of `declared` —
        # exactly the relation `Ruby::MethodBodyTypeMismatch` reports on, asked of
        # Steep's own subtyping check so the answer cannot drift from the error.
        #
        # Three-valued on purpose: `nil` is "cannot decide" — no environment, an
        # unparsable type, or a type whose meaning depends on a context this check
        # does not have (`self`/`instance`/`class`, whose referent is the enclosing
        # definition). A caller that corrects a signature on `false` must not
        # correct on `nil`, so the two are never collapsed here.
        def accepts?(declared, value)
          types = comparable_types(declared, value) or return nil
          declared_type, value_type = types

          subtype?(value_type, declared_type)
        end

        # Whether `declared` and `value` are the same type up to how exactly it is
        # said, with `value` the strictly more precise of the two:
        # `("name_delete" | "delete")` against `String`, `"name_delete"` against
        # `("name_delete" | "delete")`, `Array["a"]` against `Array[String]`,
        # `["a", "b"]` against `Array[String]`, `false` against `bool`.
        #
        # Three-valued like `accepts?`.
        def literal_refinement?(declared, value)
          types = comparable_types(declared, value) or return nil
          declared_type, value_type = types
          return false unless literal_bearing?(value_type)
          return false unless subtype?(value_type, declared_type)
          return false if subtype?(declared_type, value_type)

          widened_declared = widen_shape(widen_booleans(widen_literals(declared_type)))
          widened_value = widen_shape(widen_booleans(widen_literals(value_type)))
          subtype?(widened_value, widened_declared) && subtype?(widened_declared, widened_value)
        end

        # Whether `value` is some of the alternatives the union `declared` lists,
        # and `nil` is among both or neither: `Wheel` against
        # `(Wheel | Seat | Bench)`.
        #
        # Three-valued like `accepts?`.
        def union_refinement?(declared, value)
          types = comparable_types(declared, value) or return nil
          declared_type, value_type = types
          return false unless declared_type.is_a?(Steep::AST::Types::Union)

          listed = declared_type.types
          alternatives = value_type.is_a?(Steep::AST::Types::Union) ? value_type.types : [value_type]
          alternatives.size < listed.size && (alternatives - listed).empty? &&
            includes_nil?(alternatives) == includes_nil?(listed)
        end

        private

        # Both types as Steep types, or nil where either cannot be compared.
        def comparable_types(declared, value)
          subtyping = steep_subtyping or return nil
          declared_type = context_free_type(declared, subtyping) or return nil
          value_type = context_free_type(value, subtyping) or return nil

          [declared_type, value_type]
        end

        def includes_nil?(types)
          types.any?(Steep::AST::Types::Nil)
        end

        # A signature's type string as a Steep type, or nil when it is not one this
        # check can compare.
        #
        # Names are absolutized before the factory sees them: a signature writes
        # `Filter`, and the definition every subtyping question ends at is filed
        # under `::Filter`. A relative name resolves to nothing, which the rescue
        # would report as "cannot decide" for every type in the project.
        def context_free_type(string, subtyping)
          parsed = RBS::Parser.parse_type(string)
          return nil if context_dependent?(parsed)

          absolute = parsed.map_type_name { |name, _, _| name.absolute! }
          return nil unless known_type_names?(absolute)

          subtyping.factory.type(absolute)
        rescue RBS::ParsingError, RBS::BaseError
          nil
        end

        def subtype?(sub_type, super_type)
          steep_subtyping.check(
            Steep::Subtyping::Relation.new(sub_type: sub_type, super_type: super_type),
            self_type: nil, instance_type: nil, class_type: nil,
            constraints: Steep::Subtyping::Constraints.empty
          ).success?
        end

        def literal_bearing?(type)
          return true if type.is_a?(Steep::AST::Types::Literal)

          type.each_child.any? { |child| literal_bearing?(child) }
        end

        def widen_literals(type)
          return type.back_type if type.is_a?(Steep::AST::Types::Literal)

          type.map_type { |child| widen_literals(child) }
        end

        # A tuple as the array it widens to. The equality in `literal_refinement?`
        # asks whether two types describe the same VALUES and differ only in how
        # exactly they say so, and a tuple differs from `Array[Elem]` in exactly
        # that way: it adds how many elements there are and which is which, and
        # takes nothing away. Widening only the literals leaves `["a", "b"]` and
        # `Array[String]` failing that test in the one direction a tuple can never
        # satisfy, so a body strictly more exact than its declaration would be
        # declined as a different type rather than taken as the better answer.
        # A boolean literal as `bool`. `widen_literals` answers with a literal's
        # CLASS, and the class of `false` is `FalseClass` — one arm of `bool`, not
        # `bool` — so the equality below fails in one direction for a pair that is
        # the same type said two ways. `bool` IS `(true | false)` by definition, so
        # widening a boolean to it is what widening means here.
        #
        # Only in `literal_refinement?`. `Specializations.widen_literals` is Steep's
        # and keys specialization on the class, where the class is the answer.
        def widen_booleans(type)
          return Steep::AST::Types::Boolean.new if boolean_class?(type)

          type.map_type { |child| widen_booleans(child) }
        end

        def boolean_class?(type)
          type.is_a?(Steep::AST::Types::Name::Instance) &&
            ["::TrueClass", "::FalseClass"].include?(type.name.to_s)
        end

        def widen_shape(type)
          if type.is_a?(Steep::AST::Types::Tuple)
            elements = type.types.map { |element| widen_shape(element) }
            return Steep::AST::Builtin::Array.instance_type(
              Steep::AST::Types::Union.build(types: elements)
            )
          end

          type.map_type { |child| widen_shape(child) }
        end

        # Whether the environment defines every name in `type`. A name it does not
        # know has no definition to compare against, and an unknown ALIAS makes the
        # subtyping check raise (`RBS::DefinitionBuilder#expand_alias2`), so this is
        # asked up front instead of rescued after.
        def known_type_names?(type)
          env = SteepEnvironment.definition_builder&.env
          return true unless env

          names = [] # : Array[RBS::TypeName]
          type.map_type_name do |name, _, _|
            names << name
            name
          end
          names.all? { |name| env.type_name?(name) }
        end

        # `self`, `instance` and `class` name whatever definition encloses them, and
        # this check has no enclosing definition — comparing them against a concrete
        # type would answer about a type neither side wrote.
        def context_dependent?(type)
          return true if type.is_a?(RBS::Types::Bases::Self) ||
                         type.is_a?(RBS::Types::Bases::Instance) ||
                         type.is_a?(RBS::Types::Bases::Class)

          type.each_type.any? { |t| context_dependent?(t) }
        end
      end
    end
  end
end
