# frozen_string_literal: true

# A nested module SIDE BY SIDE with a nested class, in a body that declares
# nothing else. That combination is what used to lose `Foo` entirely.
#
# `TargetDiscovery` drops a declaration whose body is only other declarations —
# a pure namespace has no members of its own, and each nested class is emitted
# as a target in its own right. A nested MODULE is not: it is excluded from the
# targets on purpose, because the `owner` mechanism writes it inside its
# enclosing target's block. So dropping `Example22` dropped the only block
# `Foo` could ever be written into, and the file emitted `Example22::Bar`
# alone.
#
# It takes both halves to show it: without `Bar` nothing in the file is a
# target, and the single-target path lands on `Example22` anyway; with a member
# of its own `Example22` stops being a namespace and stays a target. Neither
# spelling reaches the case.
#
# The bodies are the `extend` shape on purpose — `Bar.bazingado`'s `super`
# resolves through `extend Example22::Foo` into the module, which only works
# while `Foo` is emitted.
class Example22
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo)
      base_foo.log_something("bazingado")
    end
  end

  class Bar
    extend Example22::Foo

    def self.bazingado(base_foo)
      super

      base_foo.log_something("bazingado bar")
    end

    def self.log_something(message)
      puts message
    end
  end
end
