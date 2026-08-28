class Example54
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
    extend Example54::Foo

    banana_class_method do
      def age
        31
      end
    end
  end
end
