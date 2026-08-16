class Example36
  class Foo
    def self.bazinga(*modules)
      modules.reverse_each do |mod|
        mod.bazingado(self)
      end
    end

    def self.bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  class Baz < Example36::Foo
    bazingado do
      def age
        31
      end
    end
  end

  class Bar < Baz
    bazinga(Example36::Baz)

    def call_age
      age + 10
    end
  end
end
