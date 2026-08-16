class Example34
  module Foo
    def include(*modules)
      modules.reverse_each do |mod|
        mod.bazingado(self)
      end
    end

    def included(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  module Baz
    extend Example34::Foo

    included do
      def age
        31
      end
    end
  end

  class Bar
    extend Example34::Foo

    include(Example34::Baz)
  end
end
