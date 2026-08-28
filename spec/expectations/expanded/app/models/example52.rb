class Example52
  module Foo
    def banana_class_method(&block)
      mod = const_defined?(:BananaMethods) ? const_get(:BananaMethods) : const_set(:BananaMethods, Module.new)
      mod.module_eval(&block)
    end

    def included(base)
      base.extend(const_get(:BananaMethods)) if const_defined?(:BananaMethods)
    end
  end

  module Baz
    extend Example52::Foo

    banana_class_method do
      def age
        31
      end
    end
  end

  class Bar
    include(Example52::Baz)

    def self.call_age
      age + 10
    end
  end
end

module Example52::Baz::BananaMethods
  def age
    31
  end
end

class Example52::Bar
  extend Example52::Baz::BananaMethods
end
