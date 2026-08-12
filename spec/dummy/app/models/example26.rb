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
# What is RECORDED in the steep baseline is what neither the sidecar nor RBS can state.
# rbs_infer reads the correlation and types each side by its own path; Steep checks the
# call once, and for a union receiver it requires the argument to satisfy EVERY branch at
# once — hence `singleton(Bar) & singleton(BarOther)`, a type nothing is. Its rule is
# right for a fixed argument; `self` here is not fixed, it varies with the branch. Under
# the declared surface of `bazinga` the two signatures really are contradictory, and only
# the whole-program reading makes them true. Checking a union-receiver call per PATH is
# what would close it — felixefelip/steep#143.
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
