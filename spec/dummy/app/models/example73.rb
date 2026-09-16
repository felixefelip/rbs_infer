# Array literal
module Example73
  class Foo
    # type should be `["a", "b", "c"]`
    def array_fixed
      ["a", "b", "c"]
    end

    # type should be `["a", "b", "c"]`
    def array_dynamic
      parts = []
      parts << "a"
      parts << "b"
      parts << "c"
      parts
    end

    # type should be `["a", "b"]`
    def from_a_literal
      parts = ["a"]
      parts << "b"
      parts
    end

    # type should be `["a"]`
    def through_a_call
      parts = []
      fill(parts)
      parts
    end

    # type should receive arg parts as `[]` and return `["a"]`
    def fill(parts)
      parts << "a"
      parts
    end
  end
end

