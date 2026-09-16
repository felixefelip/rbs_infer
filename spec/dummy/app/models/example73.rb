# What a method hands back when the value is an array — a tuple, which says how
# many elements there are and which is which, where `Array[union]` says neither.
#
# Every array here is answered: one the body BUILDS carries its contents out,
# one it simply writes out does too, and one a CALL appends to carries what the
# call adds. `fill` is the one that stays `Array[untyped]`, and not for want of
# an answer — the answer is the caller's, and the RBS beside this file has it.
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
    # `fill` is a body this file has, and all it does with the parameter is
    # append to it — so what the call does to the array is as readable here as a
    # `<<` written on this line, and the local is carried rather than struck.
    # type should be `["a"]`
    def through_a_call
      parts = []
      fill(parts)
      parts
    end

    # The one signature with nothing to add, and the caller above is why. A
    # parameter is a NAME that holds the array, so the widening applies to it
    # like any other: declared `[ ]`, this body's own `parts << "a"` is an error
    # (`Array[bot]#<<` takes nothing), and a tuple does not grow, so the return
    # would still be `[ ]`. What comes in is the caller's in any case — a second
    # call site passing `["z"]` makes this `["z", "a"]` — and a declaration
    # holds for every caller.
    # type should stay `(Array[untyped] parts) -> Array[untyped]`
    def fill(parts)
      parts << "a"
      parts
    end
  end
end

