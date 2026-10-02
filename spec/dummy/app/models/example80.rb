# The names handed on as an array — felixefelip/steep#171, item 2.
#
# `Module#delegate` takes its names as a rest parameter and does not loop over
# them itself: it hands the array to `Delegation.generate(owner, methods, …)`,
# which builds one source by pushing onto an array in a loop and evals the
# `join`. This is that shape and nothing else, written in the app so no gem
# stub is in the way.
#
# Three things have to hold for the generated methods to exist:
#
#   - in `forward`, checked for one call site, `methods` holds exactly the names
#     that call wrote. A rest parameter's type says what each name is and never
#     how many; the call builds the array, so the call says;
#   - handing it to `generate` keeps that. The array is named nowhere else in
#     `forward`, so what `generate` receives is what the call wrote, and the
#     call to `generate` is keyed on it;
#   - in `generate`, `methods` arrives holding that tuple, so the loop has one
#     pass per name, and `allow_nil` decides the arm each pass pushes under.
#
# The RBS beside this file is the result: `Account#email`/`#name` and
# `Order#name` exist, and are typed by what they forward to; the expanded source
# shows `Order#name` written by the `allow_nil` arm. Nothing here states a type.
#
# The writer and the base class have names no other example uses: rbs_infer
# attributes a call by its bare constant name across namespaces, so a second
# `Writer.generate` would be read as example77's.
module Example80
  module Forwarder
    def self.generate(owner, methods, to:, allow_nil: nil)
      receiver = to.to_s
      method_def = []
      methods.each do |method|
        if allow_nil
          method_def << "def #{method}" << "  _ = #{receiver}" << "  _&.#{method}" << "end"
        else
          method_def << "def #{method}" << "  #{receiver}.#{method}" << "end"
        end
      end
      owner.module_eval(method_def.join(";"))
      nil
    end
  end

  class Person
    def email = "ana@example.com"
    def name = "Ana"
  end

  class Forwarding
    def self.forward(*methods, to:, allow_nil: nil)
      Forwarder.generate(self, methods, to: to, allow_nil: allow_nil)
    end
  end

  class Account < Forwarding
    def user = Person.new

    forward :email, :name, to: :user
  end

  class Order < Forwarding
    def buyer = Person.new

    forward :name, to: :buyer, allow_nil: true
  end
end
