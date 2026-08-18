class Example43
  module Foo
    def bazinga(*modules)
      modules.reverse_each do |mod|
        mod.send(:bazingado, self)
      end
    end

    private

    def bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  class Baz
    extend Example43::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class BazOther
    extend Example43::Foo

    bazingado do
      def name
        "John Doe"
      end
    end
  end

  class Bar
    extend Example43::Foo

    bazinga(Example43::Baz)

    def call_age
      age + 10
    end
  end

  class BarOther
    extend Example43::Foo

    bazinga(Example43::Baz)

    def call_age
      age + 20
    end
  end

  class BarOther2
    extend Example43::Foo

    bazinga(Example43::Baz, Example43::BazOther)

    def call_age
      age + 20
    end

    def call_name
      name.upcase
    end
  end
end
