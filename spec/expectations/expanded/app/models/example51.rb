class Example51
  module Foo
    def banana_class_method(&block)
      const_set(:BananaMethods, Module.new).module_eval(&block)
    end
  end

  module Baz
    extend Example51::Foo

    banana_class_method do
      def age
        31
      end
    end
  end

  class Bar
    def methods_module
      Example51::Baz::BananaMethods
    end
  end
end

module Example51::Baz::BananaMethods
  def age
    31
  end
end
