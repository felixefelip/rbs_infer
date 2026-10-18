# A local hash holding another hash, handed to methods that read the inner
# hash and one that writes into it.
#
#   - `call_num1` should return 5 and `call_num2` 10.
#   - `change_num2` writes 30 under `:num2` and should return 30.
#   - `run` reads `:num2` back after it: it should return "30".
#
# Nothing here states a type.
module Example98
  class Foo
    def run
      my_hash = {}
      my_hash[:bar] = { num1: 5, num2: 10 }
      call_num1(my_hash)
      call_num2(my_hash)
      change_num2(my_hash)
      my_hash[:bar][:num2].to_s
    end

    def call_num1(my_hash)
      my_hash[:bar][:num1]
    end

    def call_num2(my_hash)
      my_hash[:bar][:num2]
    end

    def change_num2(my_hash)
      my_hash[:bar][:num2] = my_hash[:bar][:num2] + 20
    end
  end
end
