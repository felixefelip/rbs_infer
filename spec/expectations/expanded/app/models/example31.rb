class Example31
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
    extend Example31::Foo

    bazingado do
      def age
        super + 10.5
      end
    end
  end

  module Age
    def age
      42
    end
  end

  class Bar
    extend Example31::Foo

    include Example31::Age

    bazinga(Example31::Baz)
  end
end

class Example31::Bar
      def age
        super + 10.5
      end
end
