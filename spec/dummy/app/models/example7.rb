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
      when :name
        Example7::Age.value.abs # => error: `Age.value` is nil (:age partition)
        Example7::Foo.name.upcase # => "JOHN DOE" (:name partition)
      when :age
        Example7::Foo.name.upcase # => error: `Foo.name` is nil (:name partition)
        Example7::Age.value.abs   # => 42         (:age partition)
      end
    end
  end

  # ARGUMENT-SENSITIVE FACTS ("peça (3)"). `show`'s WHOLE-METHOD entry facts are
  # the meet over its call sites: `run_name` establishes `Foo.name`, `run_age`
  # establishes `Age.value`. Neither fact holds at BOTH sites, so the meet drops
  # both — reading either const outside the `case` is still an error.
  #
  # The fork now also records entry facts PARTITIONED by the literal argument:
  # the `:name` partition carries only what the callers passing `:name` proved
  # (`Foo.name`), the `:age` partition only `Age.value`. Because a `when :name`
  # branch is reachable only for those callers, the partition narrows the read
  # inside that branch — and only there. This is what lets a single shared
  # `render`/dispatcher stay precise instead of collapsing to the whole-app meet.
  def run_name
    Example7::Foo.name = 'John Doe'
    Example7::Dispatcher.new.show(:name)
  end

  def run_age
    Example7::Age.value = 42
    Example7::Dispatcher.new.show(:age)
  end
end
