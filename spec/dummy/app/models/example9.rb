class Example9
  class Foo
    def self.name
      @name
    end

    def self.name=(value)
      @name = value
    end
  end

  class Age
    def self.value
      @value
    end

    def self.value=(value)
      @value = value
    end
  end

  class Dispatcher
    # Byte-for-byte the example7 dispatcher, with ONE variable changed:
    # `case which / when :name` became `if which == :name / elsif`. Everything
    # else — the two call sites, the establishing writes, the literals — is
    # identical, so the difference in outcome isolates exactly one thing.
    #
    # The PRODUCER side is indifferent to this: it partitions facts by the
    # literal passed at each CALL SITE and never looks at the callee's body, so
    # `.steep_postconditions.yml` carries the same two partitions example7 gets
    # (`:name` -> `Foo.name`, `:age` -> `Age.value`) — verified directly against
    # the Runner.
    #
    # The CONSUMER side used to stop here: partitions were applied only in
    # `TypeInference::CaseWhen`, which runs for a `case` node, and an
    # `if which == :name` test is an ordinary `:send` predicate that nothing
    # correlated back to the `:name` partition. Both reads errored even though
    # the facts were sitting in the sidecar, already computed and partitioned.
    #
    # Both shapes now go through `TypeInference::ArgumentFacts`: an equality test
    # of a parameter against a literal selects the same partition `when :name`
    # selects, merged into the TRUTHY branch only ("not this literal" pins the
    # argument to nothing). `elsif` is a nested `if`, so it rides the same path.
    def show(which)
      if which == :name
        Example9::Foo.name.upcase # => "JOHN DOE" (:name partition)
      elsif which == :age
        Example9::Age.value.abs # => 42         (:age partition)
      end
    end
  end

  def run_name
    Example9::Foo.name = 'John Doe'
    Example9::Dispatcher.new.show(:name)
  end

  def run_age
    Example9::Age.value = 42
    Example9::Dispatcher.new.show(:age)
  end
end
