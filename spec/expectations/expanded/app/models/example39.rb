module Example39
  module Foo
    private

    def bananed(base = nil, &block)
      if base.nil?
        @_bananed_block = block
      else
        base.class_eval(&@_bananed_block) if @_bananed_block
      end
    end
  end

  module Baz
    extend Example39::Foo

    bananed do
      def age
        31
      end
    end
  end

  class Bar
    extend Example39::Foo

    banana(Example39::Baz)

    def call_age
      age + 10
    end
  end
end

class Example39::Bar
      def age
        31
      end
end
