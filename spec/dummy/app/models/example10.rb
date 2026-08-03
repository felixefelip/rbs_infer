class Example10
  class Foo
    def self.name
      @name
    end

    def self.name=(value)
      @name = value
    end
  end

  class Sink
    def self.last
      @last
    end

    def self.last=(value)
      @last = value
    end
  end

  class Bar
    # Reached ONLY from the right-hand side of a constant write in `run`, where
    # `Foo.name` is already established — so a human reading the source sees this
    # read as non-nil.
    def greet
      Example10::Foo.name.upcase # should: "JOHN DOE"; actual: error (const RHS gap)
    end
  end

  # CONST-WRITE RHS gap. `method_events` classifies `Const.attr = <rhs>` as a
  # `:const_write` event and stops there: the RHS is never walked for calls, so
  # `Bar.new.greet` is invisible to the flow and `greet` never receives the
  # `Foo.name` fact established one line above.
  #
  # The RHS runs BEFORE the assignment, so its calls belong to the flow in that
  # order — exactly the reasoning already applied to `@x = <rhs>` when ivar
  # writes were introduced (felixefelip/steep#91). There, classifying the
  # statement as a write initially swallowed the RHS calls and dropped the entry
  # facts of 12 dummy methods; it was fixed by recording the RHS calls first,
  # then the write. Constant writes never had that treatment — this fixture is
  # the pre-existing half of the same shape.
  #
  # Note the gap is about which CALLS are visited, not about the write itself.
  # What `Sink.last` is established AS does follow from it, though: while `greet`
  # errors it is `untyped`, so the write says nothing about the type. It read
  # `Example10::Bar` until felixefelip/rbs_infer#168 — the receiver of the RHS,
  # which begins at the same column as the RHS itself and so answered for it
  # while the map was keyed by a position. Closing the gap above is what would
  # make this a `String`.
  def run
    Example10::Foo.name = 'John Doe'
    Example10::Sink.last = Example10::Bar.new.greet # RHS call NOT walked -> greet errors
  end
end
