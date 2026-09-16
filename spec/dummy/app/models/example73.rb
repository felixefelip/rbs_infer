# What a method hands back when the value is an array — a tuple, which says how
# many elements there are and which is which, where `Array[union]` says neither.
#
# `array_dynamic` and `from_a_literal` are answered: an array the body BUILDS
# carries its contents out. The three that are not are each blocked on something
# different, and the RBS beside this file says which.
module Example73
  class Foo
    # The one case that is NOT about the accumulator, and the one that has to be
    # decided in the checker rather than here: Steep types an array literal as
    # `Array[String]` — widening the elements — wherever nothing asks it for a
    # tuple, because a tuple makes `<<` and every other mutation demand the
    # first element's type. Emitting the tuple from the generator alone puts the
    # two out of agreement, and the pass that corrects a declaration the body
    # contradicts (rightly) removes it again.
    # type should be `["a", "b", "c"]`
    def array_fixed
      ["a", "b", "c"]
    end

    # type should be `["a", "b", "c"]`
    def array_dynamic
      parts = []
      parts << "a"
      parts << "b"
      parts << "c"
      parts
    end

    # type should be `["a", "b"]`
    def from_a_literal
      parts = ["a"]
      parts << "b"
      parts
    end

    # The interprocedural half: what a method does to an array it is HANDED.
    # Deferred deliberately — the body is still struck, because a callee that
    # pushed is a content the walk over this body cannot see.
    # type should be `["a"]`
    def through_a_call
      parts = []
      fill(parts)
      parts
    end

    # type should receive arg parts as `[]` and return `["a"]`
    def fill(parts)
      parts << "a"
      parts
    end
  end
end

