class Example48
  module Foo
    def included(base)
      base.extend(const_get(:BananaMethods))
    end
  end

  module Baz
    extend Example48::Foo

    module BananaMethods
      def age
        31
      end
    end
  end

  class Bar
    include(Example48::Baz)

    def self.call_age
      age + 10
    end
  end
end

class Example48::Bar
  extend Example48::Baz::BananaMethods
end
