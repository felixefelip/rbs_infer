# Example98's hash of hashes, kept by an object and reached through its
# reader by each method of another one.
#
#   - `build_my_hash` should return `{ num1: 5, num2: 10 }`.
#   - `call_num1` should return 5 and `call_num2` 10.
#   - `change_num2` writes 30 under `:num2` and should return 30.
#   - `Foo#my_hash_sum_num`, called after it, should return 35.
#   - `run` reads `:num2` back: it should return "30".
#
# Nothing here states a type.
module Example99
  class Foo
    attr_reader :my_hash

    def initialize(my_hash)
      @my_hash = my_hash
    end

    def my_hash_sum_num
      @my_hash[:bar][:num1] + @my_hash[:bar][:num2]
    end
  end

  class Runner
    attr_reader :foo

    def run
      @foo = Foo.new({})
      build_my_hash
      call_num1
      call_num2
      change_num2
      foo.my_hash_sum_num
      foo.my_hash[:bar][:num2].to_s
    end

    def build_my_hash
      foo.my_hash[:bar] = { num1: 5, num2: 10 }
    end

    def call_num1
      foo.my_hash[:bar][:num1]
    end

    def call_num2
      foo.my_hash[:bar][:num2]
    end

    def change_num2
      foo.my_hash[:bar][:num2] = foo.my_hash[:bar][:num2] + 20
    end
  end
end
