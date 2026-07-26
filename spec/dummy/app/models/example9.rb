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
    # The CONSUMER side is where it stops. Partitions are applied in
    # `TypeInference::CaseWhen`, which only runs for a `case` node; an
    # `if which == :name` test is an ordinary `:send` predicate that nothing
    # correlates back to the `:name` partition. So both reads are baselined
    # errors even though the facts needed to type them are sitting in the
    # sidecar, already computed and correctly partitioned.
    #
    # Closing it means recognizing an equality test against a literal on a
    # method parameter as the same correlation `when :name` expresses, and
    # merging that partition into the truthy branch's env — the `if` analogue of
    # what CaseWhen.apply_argument_facts already does.
    def show(which)
      if which == :name
        Example9::Foo.name.upcase # should: "JOHN DOE"; actual: error (consumer gap)
      elsif which == :age
        Example9::Age.value.abs # should: 42;         actual: error (consumer gap)
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
