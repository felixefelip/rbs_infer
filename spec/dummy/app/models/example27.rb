# Example26's shape with the two parameters given `= nil` / `: nil` defaults, which is
# where the nil-default widening met the per-owner parameter table for the first time.
#
# `bazingado`'s two parameters arrive by different routes — `base_foo` from
# `module_included.bazingado(self)`, filed under the owner the receiver reaches
# (`Example27::Foo#bazingado`), and `message` from the bare call in `Baz`'s body, filed
# under the plain name. Reading the two entries merges them; the widening WROTE through
# that merge, into a copy that was dropped, so both parameters kept a type their own
# default is not (felixefelip/rbs_infer#235). A method with a single entry — every flat
# case, and `initialize` — was mutated in place and never showed it.
class Example27
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo=nil, message: nil)
      puts "base_foo class: #{base_foo.class}"

      puts "message: #{message}"
    end
  end

  module Baz
    extend Example27::Foo

    bazingado(message: "Hello, world!")

    # def self.bazingado(base_foo)
    #   base_foo.log_something("bazingado")
    # end
  end

  class Bar
    extend Example27::Foo

    # Runs at class-body time, so `Baz` above has to be defined already.
    bazinga(Example27::Baz)
  end
end
