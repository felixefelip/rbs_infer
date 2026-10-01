# The owner handed over as an argument — felixefelip/steep#171.
#
# example76 reflects on a class it names: `Peel.singleton_class`. ActiveSupport
# does not; `Delegation.generate(owner, methods, …)` reflects on the object it
# was handed, and `Module#delegate` hands it `self`. This is that shape, and
# nothing else.
#
# Today neither call site writes anything, and neither generated method exists.
# The eval itself is placed correctly — the frame that handed `self` says where
# it lands — but the chunk is not a literal, because `owner` does not name a
# class inside `generate`. And since what `class_eval` is handed is a `join`
# rather than a string written out, an argument that does not fold is not an
# eval at all to `Evals`: the call site is absent from
# `.steep_string_evals.yml`, not recorded as a hole.
#
#   - the tuple handed to `generate` carries `self` UNRESOLVED, and inside
#     `Writer.generate` a `self` means `singleton(::Writer)`, so the reflection
#     asks `Writer` for `human_name`;
#   - resolved against the frame, it would be `singleton(::Peel)` — which is
#     enough for `human_name`, written on the class that defines the macro, and
#     not for `nick`, written on a subclass: Ruby runs `banana_delegate` there
#     with `self` being `Rind`, and only the call site says so.
#
# So `human_name` closes when the handed `self` is resolved, and `nick` when a
# specialization is keyed by the receiver of its call site as well as by its
# arguments.
#
# `Example77::Writer.generate` is written qualified on purpose. Written as
# `Writer.generate`, which is how anyone would write it inside `Example77`, the
# call is not recognised as handing `self` over at all: that recognition reads
# the constant's SPELLING (`Writer.generate`) where the definition is keyed by its
# full name (`Example77::Writer.generate`), so the call site does not even show
# up as a hole in `.steep_string_evals.yml`. A second gap, not this one.
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

    # should be `("all" index) -> "ALL"` on `Peel`
    banana_delegate :human_name
  end

  class Rind < Peel
    def self.nick(name)
      name
    end

    # should be `("x" name) -> "x"` on `Rind`
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
