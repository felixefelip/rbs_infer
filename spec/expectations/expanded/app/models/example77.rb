# The owner handed over as an argument — felixefelip/steep#171.
#
# example76 reflects on a class it names: `Peel.singleton_class`. ActiveSupport
# does not; `Delegation.generate(owner, methods, …)` reflects on the object it
# was handed, and `Module#delegate` hands it `self`. This is that shape, and
# nothing else.
#
# Two things have to be right for either generated method to exist:
#
#   - the `self` handed to `generate` is the CALLER's self. Typed as written it
#     is `self`, a variable the callee binds to its own receiver, and inside
#     `Writer.generate` that is `singleton(::Writer)` — so the reflection would
#     ask `Writer` for `human_name`. Resolved in the frame that wrote it, it is
#     the class the macro runs in;
#   - which class that is depends on the call site. `banana_delegate` is defined
#     on `Peel`, but Ruby runs `banana_delegate :nick` with `self` being `Rind`,
#     and `nick` is only there. So the body is checked once per call site with
#     the `self` that call site gives it, not once with the one its definition
#     does.
#
# With both, the reflection reads `(name)` off `Rind.nick` and `(index)` off
# `Peel.human_name`, the joined chunk folds, and each lands on the class whose
# body made the call. The RBS beside this file is the result: `label` and
# `nickname` are the literals the class methods return. Nothing here states a
# type.
#
# `Example77::Writer.generate` is written qualified on purpose. Written as
# `Writer.generate`, which is how anyone would write it inside `Example77`, the
# call is not recognised as handing `self` over at all: that recognition reads
# the constant's SPELLING (`Writer.generate`) where the definition is keyed by its
# full name (`Example77::Writer.generate`), so the call site does not even show
# up as a hole in `.steep_string_evals.yml`. A gap of its own, still open.
module Example77
  module Writer
    def self.generate(owner, method)
      argument = owner.singleton_class.public_instance_method(method).parameters[0][1]

      owner.class_eval [
        "def #{method}(#{argument})",
        "  self.class.#{method}(#{argument})",
        "end"
      ].join(";")
    end
  end

  class Peel
    def self.human_name(index)
      index.upcase
    end

    def self.banana_delegate(method)
      Example77::Writer.generate(self, method)
    end

    banana_delegate :human_name
  end

  class Rind < Peel
    def self.nick(name)
      name
    end

    banana_delegate :nick
  end

  class Eater
    def label
      Peel.new.human_name("all")
    end

    def nickname
      Rind.new.nick("x")
    end
  end
end

class Example77::Peel
  def human_name(index);  self.class.human_name(index);end
end

class Example77::Rind
  def nick(name);  self.class.nick(name);end
end
