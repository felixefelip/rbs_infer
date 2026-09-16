# Array literal
module Example73
  class Foo
    def array_fixed
      ["a", "b", "c"]
    end

    def array_dynamic
      parts = []
      parts << "a"
      parts << "b"
      parts << "c"
      parts
    end
  end
end

