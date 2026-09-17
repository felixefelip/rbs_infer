# A delegation macro written out in plain Ruby, and read the way the checker
# reads any other value — felixefelip/steep#171.
#
# Nothing here is special-cased. `banana_delegate` is not a name the tooling
# knows; it is a class method whose body builds a string and hands it to
# `class_eval`, and every step of that is an ordinary question about values:
#
#   - `to.to_s` on a literal symbol is a literal string (steep#168);
#   - `RESERVED.include?(receiver)` is decided, because the constant is written
#     once in this file and only read (steep#185);
#   - so the guard is decided, and the local keeps the literal it had rather
#     than widening to a union of both arms (steep#185);
#   - the array of chunks joins to one literal (steep#172);
#   - and a literal handed to `class_eval` IS the source the call site writes
#     (steep#169), placed on the class whose body holds the call (steep#173,
#     steep#178).
#
# The RBS beside this file is the result: `email` and `human_name` exist on
# `Peel`, with the types their bodies give them, and nothing anywhere states
# a type for either. This is the first fixture where a macro's methods land that
# way — example71 pins WHERE an eval goes, and this one is what it takes to know
# what it says.
#
# Both call sites go through the same body and come out differently, which is
# the point of having two: `to: :user` leaves the guard false and `to: :class`
# makes it true, and each call site gets the source ITS arguments produce.
#
# This is the shape `ActiveSupport::Delegation.generate` has. Two things it does
# that this does not: it loops over `*methods`, where the pushes happen inside a
# block and the accumulator cannot count them, and it keeps its reserved names
# in a `Set` rather than an `Array`. Those are S3 and the other half of S6.
#
# Two things about the shape of this file are not cosmetic, and they were found
# from opposite directions:
#
# The class names are deliberately not `Post` and `User` — which is what this
# file was written with first, those being what anyone calls a delegation
# example. With them `email` came out `String?`: `user.email` resolved against
# the dummy's OWN `Post` and `User` rather than these, and rbs_rails types that
# column nilable. Neither the macro nor the eval had anything to do with it; it
# is `MethodTypeResolver` matching a receiver by bare class name.
#
# The delegation target is in THIS file rather than one of its own, and that
# one went the other way round: a file of its own is where a real target lives,
# so it was moved out — and then nothing landed at all and no eval was
# recorded, three full loop rounds with an empty sidecar. It is back here
# because that is what these answers rest on, not because it reads better.
module Example75
  class Skin
    def email
      "user@example.com"
    end
  end

  class Peel
    # `self.class` is the one receiver that has to be written differently, and
    # the reason the guard exists at all.
    RESERVED = ["class", "def", "end"]

    def user
      Skin.new
    end

    def self.human_name
      "Peel"
    end

    def self.banana_delegate(method, to:)
      receiver = to.to_s
      receiver = "self.#{receiver}" if RESERVED.include?(receiver)

      class_eval [
        "def #{method}",
        "  #{receiver}.#{method}",
        "end"
      ].join(";")
    end

    # type should be `() -> 'user@example.com'` on `Peel`
    banana_delegate :email, to: :user

    # The reserved arm: `to: :class` has to be written `self.class`, which is
    # what the guard is for.
    # type should be `() -> 'Peel'` on `Peel`
    banana_delegate :human_name, to: :class
  end
end
