class Example44
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
    extend Example44::Foo

    included do
      def age
        31
      end
    end
  end

  class Bar
    extend Example44::Foo

    include(Example44::Baz)

    def call_age
      age + 10
    end
  end

  class BarOther
    extend Example44::Foo

    include(Example44::Baz)

    def call_age
      age + 20
    end
  end
end
