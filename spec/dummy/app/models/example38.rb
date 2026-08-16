class Example38
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
    extend Example38::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class Bar
    extend Example38::Foo

    bazinga(Example38::Baz)

    def call_age
      age + 10
    end
  end
end
