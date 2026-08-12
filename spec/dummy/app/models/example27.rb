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
