class Example25
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base_foo)
      puts "base_foo class: #{base_foo.class}"
    end
  end

  module Baz
    extend Example25::Foo
  end

  module BazOther
    extend Example25::Foo
  end

  class Bar
    extend Example25::Foo

    # Runs at class-body time, so `Baz` above has to be defined already.
    bazinga(Example25::Baz)
  end

  class BarOther
    extend Example25::Foo

    bazinga(Example25::BazOther)
  end
end
