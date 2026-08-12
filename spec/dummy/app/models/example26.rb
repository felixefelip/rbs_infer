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
