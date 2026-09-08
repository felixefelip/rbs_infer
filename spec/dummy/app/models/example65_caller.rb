# The two call sites, in another file, as a real dispatch site is. Each one
# names its own subclass, which is the whole of what the inference needs and
# the whole of what it currently discards.
class Example65Caller
  def greet
    Example65Greeter.dispatch("ada", greeting: "hello")
  end

  def add
    Example65Adder.dispatch(1, step: 2)
  end

  # Through a subclass that adds nothing: still `Example65Reporter#handle`.
  def report
    Example65CsvReporter.dispatch("/tmp/x.csv")
  end

  # A different hierarchy that spells its dispatcher the same way. Its arguments
  # belong to ITS handler and to no other.
  def impersonate
    Example65Impostor.dispatch(true, mode: :fast)
  end
end
