# frozen_string_literal: true

# Nested (rather than the `RbsInfer::AST` shorthand the rest of `ast/` uses) so
# an extension can require this file on its own, before the core is loaded.
module RbsInfer
module AST
  # Ruby's constant lookup, as far as static analysis can follow it.
  #
  # A constant written bare inside `A::B` does NOT mean the top-level constant of
  # that name: Ruby searches the lexical scope from the inside out, so `Foo` means
  # `A::B::Foo`, then `A::Foo`, then `::Foo` — first one that exists wins. Matching
  # the bare name against the top level alone silently misses the nested class the
  # code actually refers to, and the miss is invisible: the type just comes out
  # `untyped` (felixefelip/rbs_infer#129).
  #
  # That bug was fixed pointwise three times — in `RbsTypeLookup` (#124, an
  # `include` recorded with its lexical prefix), in the AR runtime's
  # `PseudoCodeBuilder` (#128, a `has_many` element under the owner's namespace),
  # and in the call-return path (`TypeMerger` / `MethodTypeResolver`, a namespaced
  # service called by its bare name) — before being centralized here.
  #
  # Deliberately knows nothing about WHERE constants live: callers supply the
  # existence oracle (a source-file index, an RBS declaration index, a hash of
  # scanned models). This module only decides the ORDER to try.
  module LexicalConstantResolver
    module_function

    # The candidate constant paths for `name` written inside `enclosing`, in
    # Ruby's search order (innermost scope first).
    #
    #   candidates(name: "Foo", enclosing: "A::B")  # => ["A::B::Foo", "A::Foo", "Foo"]
    #
    # A leading `::` is absolute — Ruby skips the lexical walk entirely — so the
    # only candidate is the name itself, normalized without the prefix (every
    # index in this project keys classes unprefixed).
    #
    # `enclosing` may be nil or empty (top-level code), which yields just `name`.
    # A qualified `name` (`Foo::Bar`) walks the same way: `A::B::Foo::Bar`,
    # `A::Foo::Bar`, `Foo::Bar` — Ruby resolves the FIRST segment lexically and
    # the rest relative to it.
    def candidates(name:, enclosing:)
      return [] if name.nil? || name.empty?
      return [name.delete_prefix("::")] if name.start_with?("::")

      scopes = (enclosing || "").delete_prefix("::").split("::").reject(&:empty?)
      scopes.length.downto(0).map { |i| (scopes.first(i) + [name]).join("::") }.uniq
    end

    # The same walk for a path that ALREADY carries its lexical prefix joined onto
    # the written name — the shape a collector records when it concatenates the
    # enclosing scope at parse time and only the joined string survives.
    #
    #   candidates_for("A::B::Foo")  # => ["A::B::Foo", "A::Foo", "Foo"]
    #
    # The written name is taken to be the LAST segment. A written `Foo::Bar` is
    # therefore under-approximated (`A::Foo::Bar` is not generated) — the joined
    # form has genuinely lost the boundary, which is why a caller that still has
    # both parts should use `candidates` instead.
    def candidates_for(path)
      return [] if path.nil? || path.empty?

      parts = path.delete_prefix("::").split("::")
      candidates(name: parts.last, enclosing: parts[0..-2].join("::"))
    end

    # The first candidate the block accepts, or nil when none does. The block is
    # the existence oracle — it receives each candidate path in search order and
    # returns truthy for one that exists.
    def resolve(name:, enclosing:, &exists)
      candidates(name: name, enclosing: enclosing).find(&exists)
    end
  end
end
end
