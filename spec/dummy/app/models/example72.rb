# Arrays built by `<<` — the questions the tuple-in-inference work has to answer.
#
# Nothing here evals anything. That is the point: giving `[]` followed by `<<` a
# tuple type is a property of ARRAYS, and reading a macro's source is one
# consumer of it. Stating it through a macro would test the two together and
# hide what the change costs everywhere else.
#
# Every method returns something that exposes what the checker believes about
# the array: `join` shows the text, `first` shows an element. The RBS beside
# this file is what Steep answers TODAY; where it still says `String`, that is
# either a case deferred on purpose (`looped`) or the honest answer to a body
# that does not decide (`conditional`, `aliased`, `through_a_call`).
#
# Two of these ask for more than precision. `aliased` and `through_a_call`
# mutate the array under another name, so an implementation that tracks the
# local without seeing the mutation does not answer imprecisely — it answers
# WRONG, naming a content the program does not have. They are here first
# because a tuple that lies is worse than no tuple at all.
module Example72
  class Foo
    # The straight case, and the one the whole thing exists for.
    # should be `'a;b'`
    def straight
      parts = []
      parts << "a"
      parts << "b"
      parts.join(";")
    end

    # The element rather than the text, so a wrong LENGTH shows up as well as
    # wrong contents. `Array#first` is deliberately not in the fold's table —
    # this is answered by the local being worth its tuple, not by a fold.
    # should be `'a'`
    def first_piece
      parts = []
      parts << "a"
      parts << "b"
      parts.first
    end

    # A loop over a literal collection. The array holds two elements and the
    # type of the collection says what they are, never how many — so this is
    # the case where "walk the body once" and "know the length" part ways.
    # should be `'x;y'`, and must not be `'x'`
    def looped
      parts = []
      ["x", "y"].each { |piece| parts << piece }
      parts.join(";")
    end

    # Two possible contents, and the call site does not decide between them.
    # should be `('a' | 'a;b')` or stay `String` — but never just `'a;b'`
    def conditional(flag)
      parts = []
      parts << "a"
      parts << "b" if flag
      parts.join(";")
    end

    # UNSOUND IF MISSED. Two names for one array: the push happens through the
    # other one, so a tracker following `parts` alone sees an empty array and
    # would answer `''` for a program that produces `'a'`.
    # should be `'a'`, and must not be `''`
    def aliased
      parts = []
      other = parts
      other << "a"
      parts.join(";")
    end

    # UNSOUND IF MISSED, and the shape a builder method takes. The mutation
    # happens inside a call, where nothing about `parts` is written.
    # should be `'a'`, and must not be `''`
    def through_a_call
      parts = []
      fill(parts)
      parts.join(";")
    end

    def fill(parts)
      parts << "a"
      parts
    end

    # Starting non-empty: a one-element array literal already keeps its element
    # literal today, so this says whether `<<` extends that or discards it.
    # should be `'a;b'`
    def from_a_literal
      parts = ["a"]
      parts << "b"
      parts.join(";")
    end

    # A piece the call site does not fix. The array is known to hold two
    # elements and the text is not knowable, so this must stay `String`.
    # should stay `String`
    def with_unknown(extra)
      parts = []
      parts << "a"
      parts << extra
      parts.join(";")
    end

    # Reading the array between pushes: the type at a point, not at the end.
    # should be `'a'`
    def read_midway
      parts = []
      parts << "a"
      midway = parts.join(";")
      parts << "b"
      midway
    end
  end
end
