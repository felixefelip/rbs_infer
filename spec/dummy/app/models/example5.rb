class Example5
  class Foo
    def self.name
      @name
    end

    def self.name=(value)
      @name = value
    end
  end

  class Bar
    # FIRST HOP — called directly from `run`, where `Foo.name` was just
    # established. The method-entry fact reaches `foo_name`'s entry, so the read
    # narrows. This is the same one-hop propagation example4 relies on.
    def foo_name
      Example5::Foo.name.upcase # => "JOHN DOE" (1st hop: narrows)

      deep_foo_name
    end

    # SECOND HOP — reached only THROUGH `foo_name`. At runtime `Foo.name` is
    # still established (nobody cleared it between `run` and here), so a human
    # reading the source sees this is non-nil. But the fact does not propagate
    # past the first hop: when the Runner walks `foo_name`'s body it starts with
    # no facts (it isn't seeded with `foo_name`'s own entry fact), so nothing is
    # attributed to `deep_foo_name`. A fixpoint over the call graph would close
    # this — the reusable piece that also unlocks view -> partial rendering.
    def deep_foo_name
      Example5::Foo.name.upcase # should: "JOHN DOE"; actual: error (2nd-hop gap)
    end
  end

  def run
    Example5::Foo.name = 'John Doe'

    Example5::Bar.new.foo_name # 1st hop narrows; foo_name -> deep_foo_name is the 2nd hop
  end
end
