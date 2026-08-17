class Example32
  module Foo
    def bazinga(module_included)
      module_included.bazingado(self)
    end

    def bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  module Baz
    extend Example32::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class Bar
    extend Example32::Foo

    bazinga(Example32::Baz)

    def test
      @test = "test"
    end

    def use_test
      @test.upcase if @test
    end
  end
end

class Example32::Bar
  def age
    31
  end
end
