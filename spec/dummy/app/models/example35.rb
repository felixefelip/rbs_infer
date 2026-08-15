class Example35
  class Foo
    def self.bazinga(module_included)
      module_included.bazingado(self)
    end

    def self.bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  class Baz < Example35::Foo
    bazingado do
      def age
        31
      end
    end
  end

  class Bar < Baz
    bazinga(Example35::Baz)

    def call_age
      age + 10
    end
  end
end
