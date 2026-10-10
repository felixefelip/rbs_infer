# A stored literal changed after `new`, per call site — felixefelip/steep#205,
# stage 2.
#
# `has_renamed` builds a `Reflection` with one name and renames it before
# handing it on. What `define_stored` has to read is the name the object holds
# AFTER `rename`, and each call site renames to a different literal.
#
# `@name` is not fixed for good the way example83's is: `rename` writes it.
# The object is followed instead through `reflection`, the one local that owns
# it: built here, and only ever the receiver of a call or an argument handed to
# one. `rename(to)` binds `@name` to its argument, so past `reflection.rename(as)`
# the object holds `as`, per call site. Handing it to `define_stored` is the
# last thing done with it, and the writer reads `reflection.name` as that
# literal: `articles` and `replies` are defined.
#
# A postcondition alone could not say it: `rename` gets one marker for both
# callers, `name: :articles | :replies`.
#
# Nothing here states a type.
class Example84
  class Reflection
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def rename(to)
      @name = to
    end
  end

  module Writer
    def self.define_stored(model, reflection)
      model.class_eval "def #{reflection.name}; :renamed; end"
    end
  end

  def self.has_renamed(name, as)
    reflection = Reflection.new(name)
    reflection.rename(as)
    Writer.define_stored(self, reflection)
  end

  has_renamed :posts, :articles
  has_renamed :comments, :replies

  def self.summary
    record = new
    [record.articles, record.replies]
  end
end
