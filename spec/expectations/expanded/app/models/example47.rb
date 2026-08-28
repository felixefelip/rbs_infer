class Example47
  module Foo
    def banana_class_method(&block)
      const_get(:BananaMethods).module_eval(&block)
    end
  end

  module Baz
    extend Example47::Foo

    module BananaMethods
      def color
        "yellow"
      end
    end

    banana_class_method do
      def age
        31
      end
    end
  end

  class Bar
    extend Example47::Baz::BananaMethods

    def self.call_color
      color.upcase
    end

    def self.call_age
      age + 10
    end
  end
end

module Example47::Baz::BananaMethods
  def age
    31
  end
end
