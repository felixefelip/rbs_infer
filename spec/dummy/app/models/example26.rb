# Example24's shape with the two paths CROSSED: `bazinga` is called twice, and each call
# pairs a different `module_included` with a different `self`.
#
#   bazinga(Baz)       in Bar      -> self is singleton(Bar)
#   bazinga(BazOther)  in BarOther -> self is singleton(BarOther)
#
# Read one parameter at a time those become `(Baz | BazOther)` and `(Bar | BarOther)`, and
# the pairing is gone: `module_included.bazingado(self)` then hands `BazOther.bazingado` a
# `base_foo` that may be `Bar`, which has no `log_something`. The two parameters travel
# together and the reading has to keep them together (felixefelip/rbs_infer#231).
#
# The two branches of that receiver also reach DIFFERENT methods — `Baz` has no
# `bazingado`, so it lands on `Foo`'s through the extend, while `BazOther` has its own
# `def self.` — which is the second half of the same issue: one key per branch, not the
# first that matches.
#
# And the checker follows it, which took saying it somewhere RBS cannot. Checking the
# call once, Steep merges the branches' method types and demands an argument that
# satisfies EVERY branch — `singleton(Bar) & singleton(BarOther)`, a type nothing is.
# That rule is right for a fixed argument, and `self` here is not fixed. So the sidecar
# carries a `paths` entry naming which `self` goes with which argument, and
# felixefelip/steep#143 checks such a call one branch at a time, each with its own
# `self`. This file has no baseline entry: what used to be recorded there is now
# verified.
#
# Example23 and Example24 get no `paths`, and should not: both of their invocations pass
# the SAME constant, so the argument does not separate the call sites and the two selves
# belong to one path rather than to two. Stating either would be picking one arbitrarily.
class Example26
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo)
      puts "base_foo class: #{base_foo.class}"
    end
  end

  module Baz
    extend Example26::Foo
  end

  module BazOther
    extend Example26::Foo

    def self.bazingado(base_foo)
      base_foo.log_something("bazingado")
    end
  end

  class Bar
    extend Example26::Foo

    # Runs at class-body time, so `Baz` above has to be defined already.
    bazinga(Example26::Baz)
  end

  class BarOther
    extend Example26::Foo

    def self.log_something(message)
      puts message

      message
    end

    bazinga(Example26::BazOther)
  end
end
