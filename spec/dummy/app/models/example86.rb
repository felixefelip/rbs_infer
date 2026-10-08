# An ivar an `attr_accessor` rewrites is not fixed by `initialize` —
# felixefelip/steep#219.
#
# `Box.new(:draft)` is typed as the object it builds only while nothing but
# `initialize` writes `@value` (felixefelip/steep#205, stage 1, example83). Here
# the `attr_accessor` writes it too: `publish` sets it to `:published` before
# the macro reads it back, so the method `has_stamp` defines at run time is
# `published`.
#
# The checker does not see the accessor's write: `may_write` is read from
# `def`s, and an `attr_accessor` has none. So `@value` counts as fixed, the box
# is typed `Box{@value: :draft}` past `publish`, the string folds to
# `def draft`, a method that does not exist, and `published`, which does, is a
# `NoMethod`.
#
# Once the write is seen, the box is a plain `Box` and its `value` is
# `:draft | :published`: the string does not fold and `def draft` goes away.
# `published` stays a `NoMethod` — what `publish` wrote into the object it was
# handed is a write from outside the class (felixefelip/steep#220).
#
# The write is in another method on purpose. Right after `box.value = x` the
# checker narrows `box.value` to `x` on its own; past a call, only what the
# setter may write says `@value` changed.
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
