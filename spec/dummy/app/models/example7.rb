class Example7
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
    # A shared method dispatching on a literal argument — the plain-Ruby shape
    # of a `render(:view)` dispatcher. `show` is called with `:name` from a
    # site where `Foo.name` is established, and with `:age` from a site where
    # `Age.value` is established. Each `when` runs only for its own argument, so
    # a human sees each read as non-nil.
    def show(which)
      case which
      when :name then Example7::Foo.name.upcase # should: "JOHN DOE"; actual: error (meet gap)
      when :age  then Example7::Age.value.abs   # should: 42;         actual: error (meet gap)
      end
    end
  end

  # ARGUMENT-SENSITIVE FACTS gap ("peça (3)"). `show`'s entry facts are the meet
  # over its call sites: `run_name` establishes `Foo.name`, `run_age`
  # establishes `Age.value`. Neither fact holds at BOTH sites, so the meet drops
  # both — and inside `show` the `:name` and `:age` branches see nothing, so
  # both reads error. Closing this needs entry facts partitioned by the literal
  # argument: the `when :name` branch seeded from only the callers that passed
  # `:name` (which establish `Foo.name`), the `when :age` branch from only the
  # `:age` callers. This is what a single shared `render`/dispatcher needs to
  # stay precise instead of collapsing to the whole-app meet.
  def run_name
    Example7::Foo.name = 'John Doe'
    Example7::Dispatcher.new.show(:name)
  end

  def run_age
    Example7::Age.value = 42
    Example7::Dispatcher.new.show(:age)
  end
end
