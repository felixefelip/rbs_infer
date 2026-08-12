# Example23's shape again, in its own namespace and with the same method names, which is
# the whole point: `bazinga` and `bazingado` exist in both.
#
# The invoker-self narrowing gathers call sites by method NAME across the corpus, so this
# file's callers show up when `Example23::Foo#bazinga` is asked about, and the other way
# round. They used to be read as callers nobody could place, and the narrowing declined
# for both files at once — the two namespaces blanking each other
# (felixefelip/rbs_infer#227). A bare call resolves in its caller's own ancestry, and
# `Example24::Bar` does not extend `Example23::Foo`, so it is calling something else.
#
# Deliberately thinner than Example23: no `log_something`, so nothing here depends on the
# narrowing being USED. What it pins is that Example23's narrowing survives this file
# existing, and that this file gets its own.
class Example24
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo)
      puts "base_foo class: #{base_foo.class}"
    end
  end

  module Baz
    extend Example24::Foo
  end

  class Bar
    extend Example24::Foo

    # Runs at class-body time, so `Baz` above has to be defined already.
    bazinga(Example24::Baz)
  end

  class BarOther
    extend Example24::Foo

    bazinga(Example24::Baz)
  end
end
