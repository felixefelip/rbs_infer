# A stored literal changed after `new`, per call site — felixefelip/steep#205,
# stage 2.
#
# `has_renamed` builds a `Reflection` with one name and renames it before
# handing it on. What `define_stored` has to read is the name the object holds
# AFTER `rename`, and each call site renames to a different literal.
#
# The checker already carries a state change across a call: `unconditional.ivars`
# for a call on `self`, a marker for any other receiver. Both are one fact per
# method, though: `rename` gets a single postcondition, typed `:articles |
# :replies` from both callers together, and `reflection` is not `self`. So
# `articles` and `replies` are never defined. Closing it needs exit facts per
# `(method, parameter, literal)`, the shape entry facts already have, applied to
# the state stage 1 tracks (example83).
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
