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
    # read as non-nil, and so does the checker now that the RHS is part of the
    # flow. This is the method whose return the whole chain below hangs on.
    def greet
      Example10::Foo.name.upcase # "JOHN DOE"
    end
  end

  # CONST-WRITE RHS. `method_events` classified `Const.attr = <rhs>` as a
  # `:const_write` event and stopped there: the RHS was never walked for calls,
  # so `Bar.new.greet` was invisible to the flow and `greet` never received the
  # `Foo.name` fact established one line above — `Foo.name.upcase` errored.
  #
  # The RHS runs BEFORE the assignment, so its calls belong to the flow in that
  # order — exactly the reasoning already applied to `@x = <rhs>` when ivar
  # writes were introduced (felixefelip/steep#91). There, classifying the
  # statement as a write initially swallowed the RHS calls and dropped the entry
  # facts of 12 dummy methods; it was fixed by recording the RHS calls first,
  # then the write. Constant writes got the same treatment in
  # felixefelip/steep#131, which is what this fixture now pins.
  #
  # The gap was about which CALLS are visited, not about the write itself — but
  # what `Sink.last` is established AS followed from it, because an erroring
  # `greet` is `untyped` and a write of `untyped` says nothing. That slot read
  # `Example10::Bar` until felixefelip/rbs_infer#168 (the receiver of the RHS,
  # which begins at the same column as the RHS itself, answering for it while the
  # map was keyed by a position), then `untyped`, and now `String` — what `greet`
  # returns, which is what the source said all along.
  def run
    Example10::Foo.name = 'John Doe'
    Example10::Sink.last = Example10::Bar.new.greet
  end
end
