class Example42
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
    extend Example42::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class Bar
    extend Example42::Foo

    bazinga(Example42::Baz)

    def call_age
      age + 10
    end
  end

  class BarOther
    extend Example42::Foo

    bazinga(Example42::Baz)

    def call_age
      age + 20
    end
  end
end

class Example42::Bar
  def age
    31
  end
end

class Example42::BarOther
  def age
    31
  end
end
