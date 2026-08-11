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

    bazinga(Example23::Baz)

    def self.log_something(message)
      puts message

      message
    end
  end
end

