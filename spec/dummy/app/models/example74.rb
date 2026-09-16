# A constant read for the value it was written with — S6 of felixefelip/steep#171.
#
# Nothing here evals anything, for the reason example72 gives: this is a
# property of CONSTANTS, and reading a macro's source is one consumer of it.
# The shape it exists for is one line of `ActiveSupport::Delegation.generate`:
#
#     receiver = "self.#{receiver}" if RESERVED_METHOD_NAMES.include?(receiver)
#
# Undecided, `receiver` widens to a union of two literals — and a union of
# literals collapses to `String` on the next interpolation, so the generated
# chunk is not a literal and the call site is declined for EVERY receiver, not
# only the reserved ones. `guarded` below is that line with nothing else in it.
#
# The four that must NOT answer are the point. A constant is written once by
# convention, not by enforcement, and a value read from a name the file changed
# behind the reader's back is a confident wrong answer rather than a vague one.
module Example74
  class Foo
    RESERVED = ["class", "def", "end"]
    FROZEN = %w(class self).freeze

    # Written twice: which of them a read means is a question about constant
    # lookup, not one this file answers.
    TWICE = ["a"]
    TWICE = ["b"]

    # Changed behind the read, by the method below.
    MUTATED = ["a"]

    # Handed to something that can change it.
    PASSED = ["a"]

    def name
      "content"
    end

    # type should be literal `false` — `'content'` is none of them
    def reserved_name
      RESERVED.include?(name)
    end

    # type should be literal `true`
    def spelled_out
      RESERVED.include?("def")
    end

    # type should be literal `'class;self'` — `.freeze` is how a constant
    # collection is spelled and says nothing about what is in it
    def frozen_list
      FROZEN.join(";")
    end

    # type should be literal `'  (user).x(...)'` — the guard is decided, so the
    # local keeps the value it had and the interpolation after it still folds.
    # `to` is fixed by the call site below, the way a macro's keyword is.
    def guarded(to)
      receiver = to.to_s
      receiver = "self.#{receiver}" if FROZEN.include?(receiver)
      "  (#{receiver}).x(...)"
    end

    # type should be literal `'  (user).x(...)'`
    def call_guarded
      guarded(:user)
    end

    # type should be literal `'  (self.class).x(...)'` — the OTHER arm, where
    # the guard is decided true and the name is the one being guarded against
    def call_guarded_reserved
      guarded(:class)
    end

    # type should stay `bool`
    def written_twice
      TWICE.include?("a")
    end

    # type should stay `bool`
    def mutated_elsewhere
      MUTATED.include?("a")
    end

    # The value pushed does not matter and is the same one already there — what
    # takes the constant away is that the name is written to at all.
    def mutate
      MUTATED << "a"
    end

    # type should stay `bool`
    def handed_over
      PASSED.include?("a")
    end

    def hand_over
      sink(PASSED)
    end

    def sink(list)
      list.size
    end
  end
end
