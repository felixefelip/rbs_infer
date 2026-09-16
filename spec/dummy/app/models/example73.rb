# What a method hands back when the value is an array — a tuple, which says how
# many elements there are and which is which, where `Array[union]` says neither.
#
# Three of these are answered: an array the body BUILDS carries its contents
# out, and so does one it simply writes out. The two that are not are the same
# gap seen twice, and the RBS beside this file says so.
module Example73
  class Foo
    # The one that is not about the accumulator: no local holds this array at
    # all. Everywhere else Steep widens an array literal to `Array[Elem]`, and
    # that buys the mutation a name makes possible — a tuple takes only what it
    # already holds, so `parts << "d"` on one is an error. Where the body ENDS
    # there is no name and no next statement, so there is nothing to buy.
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

