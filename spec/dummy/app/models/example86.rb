# An ivar an `attr_accessor` rewrites is not fixed by `initialize` —
# felixefelip/steep#219 — and what a method writes on the object it was handed
# reaches its caller — felixefelip/steep#228.
#
# `Box.new(:draft)` is typed as the object it builds only while nothing but
# `initialize` writes `@value` (felixefelip/steep#205, stage 1, example83). Here
# the `attr_accessor` writes it too: `publish` sets it to `:published` before
# the macro reads it back, so the method `has_stamp` defines at run time is
# `published`.
#
# The accessor's write is in `may_write` (felixefelip/steep#227), so the box is
# a plain `Box` past `publish` and does not fold to `def draft`. What folds the
# string is `publish` itself: it always leaves `:published` in the box it was
# handed (`unconditional.params`), and the call site reads `box.value` as that,
# exactly as if `box.value = :published` were written there.
#
# The write is in another method on purpose. Right after `box.value = x` the
# checker narrows `box.value` to `x` on its own; past a call, only the callee's
# postcondition says what the box holds.
#
# `fresh` is a second caller of `new`, so `value` is `:draft | :published` from
# `initialize` alone and `publish`'s write is accepted whatever the setter's own
# call site contributes.
#
# Nothing here states a type.
class Example86
  class Box
    attr_accessor :value

    def initialize(value)
      @value = value
    end
  end

  def self.fresh
    Box.new(:published)
  end

  def self.publish(box)
    box.value = :published
  end

  def self.has_stamp(name)
    box = Box.new(name)
    publish(box)
    class_eval "def #{box.value}; :stamped; end"
  end

  has_stamp :draft

  def self.summary
    new.published
  end
end
