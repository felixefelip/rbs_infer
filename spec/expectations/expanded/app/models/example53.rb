class Example53
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
    extend Example53::Foo

    banana_class_method do
      def age
        origin.length + 31
      end
    end
  end

  class Bar
    include(Example53::Baz)

    def self.origin
      "farm"
    end

    def self.call_age
      age + 10
    end
  end
end

module Example53::Baz::BananaMethods
  # @type instance: singleton(::Example53::Bar) & ::Example53::Baz::BananaMethods
  def age
    origin.length + 31
  end
end

class Example53::Bar
  extend Example53::Baz::BananaMethods
end
