class Example8
  def run_name
    @name = 'John Doe'
    show(:name)
  end

  def run_age
    @value = 42
    show(:age)
  end

  # IVAR partitions. Same dispatch as example7, but the facts each caller
  # establishes are INSTANCE VARIABLES rather than constant attributes. The
  # whole-method meet still proves neither (`run_name` sets only `@name`,
  # `run_age` only `@value`), so the partitioning by literal argument is what
  # makes each branch readable.
  #
  # An ivar fact is about the CALLER's `self`, so unlike a const it only
  # transfers across a same-self call — `show(:name)` here, not
  # `other.show(:name)` — and it is dropped if an intervening call may write the
  # ivar. Both gates are in the producer.
  def show(which)
    case which
    when :name
      @name.upcase # => "JOHN DOE" (:name partition)
    when :age
      @value.abs   # => 42         (:age partition)
    end
  end
end
