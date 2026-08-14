module Example30
  class Foo
    def name
      "Foo"
    end

    def build_age
      self.class.class_eval do
        def age
          25
        end
      end
    end

    def call_age
      age # no method error

      build_age

      age + 10 # => works -> 35
    end
  end
end

class Example30::Foo
        def age
          25
        end
end
