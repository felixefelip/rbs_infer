# A hash an object keeps, written through its reader by another object and
# read back afterwards, there and in a method called in between.
#
#   - `Runner#run` stores 10 under `:bar` and adds 10 to what it reads back:
#     it should return 20.
#   - `Runner#run_bar`, called once the key is written, should return "10".
#
# Nothing here states a type.
module Example97
  class Foo
    attr_reader :my_hash

    def initialize(my_hash)
      @my_hash = my_hash
    end
  end

  class Runner
    attr_reader :foo

    def run
      @foo = Foo.new({})
      foo.my_hash[:bar] = 10
      run_bar
      foo.my_hash[:bar] + 10
    end

    def run_bar
      foo.my_hash[:bar].to_s
    end
  end
end
