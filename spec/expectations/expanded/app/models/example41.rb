class Example41
  module Foo
    def included(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  module Baz
    extend Example41::Foo

    included do
      def age
        31
      end
    end
  end

  class Bar
    extend Example41::Foo

    include(Example41::Baz)
  end
end

class Example41::Bar
      def age
        31
      end
end
