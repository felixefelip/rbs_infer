# frozen_string_literal: true

module RbsInfer
  module Signatures
    # What signatures other than our own output already declare. Asked by
    # `RbsDefinitionResolver`, which supplies `rbs_builder` and the name helpers.
    module ForeignDeclarationLookup
      # Does some OTHER file already declare `class_name#method_name` as a plain
      # (non-overloading) member? That is the precondition for emitting the overloading
      # form: `| ...` with nothing to overload is `InvalidOverloadMethodError`, and two
      # plain declarations are `DuplicatedMethodDefinitionError` — both of which poison the
      # whole environment rather than degrading.
      #
      # `excluding_suffix` drops the declaration WE are about to rewrite. Our own previous
      # output already declares the method, and confirming against it would be circular: a
      # method only we declare would gain `| ...` and then have nothing left to overload.
      # The suffix is `<source path>.rbs`, which is stable whatever `--output-dir` is.
      #
      # An ancestor's declaration counts too, and not because the plain form would be
      # rejected — overriding a mixin's method is legal RBS and never is. It counts
      # because the override DROPS what it overrides, and the generated signature is a
      # closed union of the call sites we saw: a plain `class Object; def extend`
      # replaces core's `(*Module) -> self` outright, so an `extend` whose argument is
      # not one of the constants in that union has nothing left to resolve against. The
      # overloading form puts ours ahead and keeps the inherited one behind it — measured
      # against `DefinitionBuilder`, which answers our overload and then core's
      # `(*::Module) -> self` (felixefelip/rbs_infer#302).
      #
      # `Module#include` has always had that fallback, for the accidental reason that core
      # declares `include` on `Module` itself. `extend` lives on `Kernel`, which `Object`
      # only includes. Two transcriptions of the same kind should not differ on where core
      # happened to write the method.
      #
      # Not load-bearing for the dummy, and the mutation says so: with this rule removed
      # the baseline stays clean, because every `extend` written there names a constant
      # the union already holds. It guards the call site that does not.
      #
      # Only where something else declares the class itself. In a class only our output
      # declares, the method is an override at run time too: the parent's signature does
      # not apply to it, and keeping it would hold the body to the parent's parameters.
      def foreign_plain_declaration?(class_name, method_name, singleton:, excluding_suffix: nil)
        return false unless rbs_builder

        type_name = build_rbs_type_name(class_name)

        # A name the environment does not know has no declarations and no ancestors —
        # and asking `instance_ancestors` for one raises a bare `RuntimeError`, which is
        # not an `RBS::BaseError` and would escape the rescue below.
        return false unless type_name && rbs_builder.env.class_decls[type_name]

        return true if plain_declaration?(type_name, method_name, excluding_suffix: excluding_suffix)

        # Ancestors answer for INSTANCE members only. `singleton` is the member's own
        # kind, and the chain walked below is the instance one: a `def self.frozen?`
        # confirmed against `Kernel`'s INSTANCE `frozen?` would emit `| ...` on the
        # singleton, where there is nothing to overload — `InvalidOverloadMethodError`,
        # which poisons the whole environment rather than degrading. A singleton member
        # keeps the same-type answer it has always had.
        !singleton && inherited_plain_declaration?(type_name, method_name, excluding_suffix: excluding_suffix)
      rescue RBS::BaseError
        false
      end

      # Whether a signature other than the one ending in `excluding_suffix` declares
      # `method_name` on `class_name` itself, on the same side, in a form a second
      # plain declaration would collide with.
      def foreign_own_declaration?(class_name, method_name, singleton:, excluding_suffix:)
        type_name = rbs_builder && build_rbs_type_name(class_name) or return false

        plain_declaration?(type_name, method_name, excluding_suffix: excluding_suffix,
                                                   kind: singleton ? :singleton : :instance)
      rescue RBS::BaseError
        false
      end

      # Whether a signature other than the one ending in `excluding_suffix`
      # declares the constant `constant_name`.
      def foreign_constant_declaration?(constant_name, excluding_suffix:)
        return false unless rbs_builder

        entry = rbs_builder.env.constant_decls[build_rbs_type_name(constant_name)] or return false
        path = entry.decl.location&.buffer&.name.to_s
        !(excluding_suffix && path.end_with?(excluding_suffix))
      rescue RBS::ParsingError, RBS::BaseError
        false
      end

      private

      # The plain-member scan of ONE type's own declarations — the question
      # `foreign_plain_declaration?` asks, of the type and then of each ancestor.
      #
      # `kind: :instance` is for the ancestor pass, and pairs with the `singleton`
      # gate above: that pass runs for instance members, so it must read instance
      # declarations. The same-type scan ignores `kind` and always has — left as it is,
      # because widening it is a separate question from this one.
      def plain_declaration?(type_name, method_name, excluding_suffix:, kind: nil)
        foreign_decls(type_name, excluding_suffix: excluding_suffix).any? do |decl|
          decl.members.any? do |member|
            declared_method_names(member).include?(method_name.to_s) && (!kind || member.kind == kind)
          end
        end
      end

      def inherited_plain_declaration?(type_name, method_name, excluding_suffix:)
        return false if foreign_decls(type_name, excluding_suffix: excluding_suffix).empty?

        ancestor_type_names(type_name).any? do |ancestor|
          plain_declaration?(ancestor, method_name, excluding_suffix: excluding_suffix, kind: :instance)
        end
      end

      def foreign_decls(type_name, excluding_suffix:)
        entry = rbs_builder.env.class_decls[type_name] or return []

        entry.each_decl.reject do |decl|
          excluding_suffix && decl.location&.buffer&.name.to_s.end_with?(excluding_suffix)
        end
      end

      def declared_method_names(member)
        case member
        when RBS::AST::Members::MethodDefinition then member.overloading? ? [] : [member.name.to_s]
        when RBS::AST::Members::AttrReader then [member.name.to_s]
        when RBS::AST::Members::AttrWriter then ["#{member.name}="]
        when RBS::AST::Members::AttrAccessor then [member.name.to_s, "#{member.name}="]
        when RBS::AST::Members::Alias then [member.new_name.to_s]
        else []
        end
      end
    end
  end
end
