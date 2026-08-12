# Example22's shape with a nested MODULE among the extenders, so `Foo` is reached by
# `extend` from both a module and a class — and with TWO methods named `bazingado`, one
# per side: `Foo#bazingado` and `Baz.bazingado`. That collision is the subject
# (felixefelip/rbs_infer#215): both live in the same emitted `class Example23` block, and
# the inferred-parameter table used to key them by name alone, so whichever call site was
# read first typed them both.
#
# Two errors this file produces are RECORDED in the steep baseline, and both come from
# the same place — `self` inside a module method extended by more than one host:
#
#   1. `base_foo.log_something` inside `Baz.bazingado`. That parameter is the union over
#      `Foo`'s extenders, and `Baz` has no `log_something`. The only invocation passes
#      `Bar` — `bazinga(Example23::Baz)` runs in `Bar`'s class body — so a human reads
#      `singleton(Bar)` where the tooling reads the union. Narrowing it means correlating
#      the host that invoked `bazinga` with the `self` inside it.
#   2. `module_included.bazingado(self)` inside `Foo#bazinga`. rbs_infer types that `self`
#      as the union (`ModuleSelfTypeAnnotator` injects it); Steep does not, because its
#      module-self convention is built from `include` and nobody includes `Foo`.
class Example23
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo)
      puts "base_foo class: #{base_foo.class}"
    end
  end

  module Baz
    extend Example23::Foo

    def self.bazingado(base_foo)
      base_foo.log_something("bazingado")
    end
  end

  class Bar
    extend Example23::Foo

    def self.log_something(message)
      puts message

      message
    end

    # Runs at class-body time, so everything it reaches has to be defined
    # already: `Baz` above, and `log_something` right here.
    bazinga(Example23::Baz)
  end
end
