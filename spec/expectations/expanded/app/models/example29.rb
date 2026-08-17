class Example29
  module Foo
    attr_reader :bazingado_block

    def bazinga(module_included)
      class_eval(&module_included.bazingado_block)
    end

    def bazingado(&block)
      @bazingado_block = block
    end
  end

  module Baz
    extend Example29::Foo

    bazingado do
      validade_age

      def greet
        "Hello, world!"
      end

      def age_after_a_decade
        age + 10
      end
    end
  end

  class Bar
    extend Example29::Foo

    def self.validade_age
      "validating age"
    end

    bazinga(Example29::Baz)

    def age
      42
    end

    def call_test
      greet
    end
  end

  module BazOther
    extend Example29::Foo

    bazingado do
      def name_upcase
        name.upcase
      end
    end
  end

  class BarOther
    extend Example29::Foo

    bazinga(Example29::BazOther)

    def name
      "John Doe"
    end

    def call_name_upcase
      name_upcase
    end
  end
end

class Example29::Bar
  validade_age

  def greet
    "Hello, world!"
  end

  def age_after_a_decade
    age + 10
  end
end

class Example29::BarOther
  def name_upcase
    name.upcase
  end
end
