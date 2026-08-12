# Example22's shape with a nested MODULE among the extenders, so `Foo` is reached by
# `extend` from both a module and a class — and with TWO methods named `bazingado`, one
# per side: `Foo#bazingado` and `Baz.bazingado`. That collision is the subject
# (felixefelip/rbs_infer#215): both live in the same emitted `class Example23` block, and
# the inferred-parameter table used to key them by name alone, so whichever call site was
# read first typed them both.
#
# It is also where the `self` a module method passes on gets narrowed
# (felixefelip/rbs_infer#222). `Foo`'s declared `self` is the union over all three
# extenders, which is right as a declaration and too wide as an ARGUMENT: `bazinga` is
# called from `Bar` and from `BarOther`, and from nowhere else, so the `self` it hands to
# `Baz.bazingado` is those two and not `Baz` — which is what lets
# `base_foo.log_something` resolve, closing the chain down to both return types.
#
# TWO callers rather than one, deliberately. With a single one the narrowing is a lone
# `singleton(Bar)`, and a union is where the spelling starts to matter: `(A | B)` is a
# type RBS reads happily and an annotation Steep refuses, because its parser re-reads the
# parsed node's own location and RBS drops the outer parenthesis from it. One caller kept
# that hidden (felixefelip/rbs_infer#225).
#
# And the same narrowing reaches the checker (felixefelip/rbs_infer#221), which it has
# to or the two halves disagree: rbs_infer would type the call site narrowly while Steep
# still read `bazinga`'s own `self` as the full union, and the body could not pass its
# `self` to the parameter it had just typed. One line per module cannot say it —
# `bazinga` narrows, `bazingado` does not (nobody calls it) — so the sidecar carries a
# `defs` entry and the annotation rides `bazinga`'s signature line. This file type-checks
# with no baseline entry; both of the ones it used to have are gone.
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

  class BarOther
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
