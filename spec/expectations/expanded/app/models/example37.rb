class Example37
  module Foo
    def bazinga(*modules)
      modules.reverse_each do |mod|
        mod.bazingado(self)
      end
    end

    def bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  class Baz
    extend Example37::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class Bar
    extend Example37::Foo

    bazinga(Example37::Baz)

    def call_age
      age + 10
    end
  end
end

class Example37::Bar
  def age
    31
  end
end
