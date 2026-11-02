# frozen_string_literal: true

module RbsInfer
  module Signatures
    # The superclass a generated declaration writes. A reopen that names one must
    # name the one every other declaration of the class names, or RBS rejects it
    # (SuperclassMismatchError) and the whole environment goes down with it:
    # gem_rbs_collection's `class Uncountables[T] < Array[T]` against the
    # source's `class Uncountables < Array`, which reads `Array[untyped]`.
    module DeclaredSuperclass
      module_function

      # `RbsBuilder`'s `superclass_name:` and `superclass_args:`: the source's
      # superclass, or the declared one where the environment already declares
      # the class with another.
      def written(target_class, superclass_name, resolver)
        name, args = superclass(target_class, superclass_name, resolver)
        { superclass_name: name, superclass_args: args }
      end

      def superclass(target_class, superclass_name, resolver)
        return [nil, ""] unless superclass_name

        written = [superclass_name, resolver.type_param_string(superclass_name, untyped: true)]
        declared = declared(target_class, resolver) or return written
        same?(declared, written, target_class, resolver) ? written : declared
      end

      # `[name, args]` as the primary declaration writes it, in its own type
      # variables (`["::Array", "[T]"]`), or nil where none names a superclass.
      def declared(target_class, resolver)
        entry = resolver.declaration(target_class)
        superclass = entry.primary_decl.super_class if entry.is_a?(RBS::Environment::ClassEntry)
        [superclass.name.to_s, superclass.args.empty? ? "" : "[#{superclass.args.join(", ")}]"] if superclass
      rescue StandardError
        nil
      end

      # The source's name, resolved from where the class is written, is the
      # declared superclass, or an alias of it (`Store < Implementation`, where
      # `Implementation = MriBackend`, written so on purpose: `ClassAlias`).
      def same?(declared, written, target_class, resolver)
        name = declared[0].delete_prefix("::")
        return false unless declared[1] == written[1]

        candidates(target_class, written[0]).any? { |full| full == name || alias_of(full, resolver) == name }
      end

      def candidates(target_class, written_name)
        return [written_name.delete_prefix("::")] if written_name.start_with?("::")

        nesting = target_class.split("::")[0...-1]
        nesting.size.downto(0).map { |depth| [*nesting.take(depth), written_name].join("::") }
      end

      def alias_of(full, resolver)
        entry = resolver.declaration(full)
        entry.decl.old_name.to_s.delete_prefix("::") if entry.is_a?(RBS::Environment::ClassAliasEntry)
      end
    end
  end
end
