class Example45
  module Foo
    def banana_class_method(&block)
      @_banana_block = block
    end

    def included(base)
      base.singleton_class.class_eval(&@_banana_block) if @_banana_block
    end
  end

  module Baz
    extend Example45::Foo

    banana_class_method do
      def age
        31
      end
    end
  end

  class Bar
    include(Example45::Baz)

    def self.call_age
      age + 10
    end
  end

  class BarOther
    include(Example45::Baz)

    def self.call_age
      age + 20
    end
  end
end

class Example45::Bar
  class << self
    def age
      31
    end
  end
end

class Example45::BarOther
  class << self
    def age
      31
    end
  end
end
