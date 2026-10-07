# A literal stored in an object, read back in another method — felixefelip/steep#205,
# stage 1.
#
# Both macros below write `def <name>` from the same literal, through a writer
# that is handed the class. `has_direct` hands the writer the literal itself,
# and the writer is read under each macro call's arguments, so `tags` and
# `labels` are defined. `has_stored` puts the literal in a `Reflection` first
# and the writer reads it back with `reflection.name`. An argument is known by
# its RBS type, which for that one is just `Reflection`, so the writer is read
# the same way for both callers: `reflection.name` is `:posts | :comments`, the
# string does not fold, and `posts` and `comments` are never defined.
#
# Two callers per macro on purpose. With one, the closed world types the reader
# `:posts`, and the fold works by accident.
#
# `has_many :posts` is this shape: the name goes into a reflection and comes
# back out as `reflection.name` before `define_accessors` interpolates it.
#
# Nothing here states a type.
class Example83
  class Reflection
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  # Writes on the class it is handed, as `Builder::HasMany.build(model, …)`
  # and `define_accessors(model, reflection)` do.
  module Writer
    def self.define_direct(model, name)
      model.class_eval "def #{name}; :direct; end"
    end

    def self.define_stored(model, reflection)
      model.class_eval "def #{reflection.name}; :stored; end"
    end
  end

  def self.has_direct(name)
    Writer.define_direct(self, name)
  end

  def self.has_stored(name)
    Writer.define_stored(self, Reflection.new(name))
  end

  has_direct :tags
  has_direct :labels
  has_stored :posts
  has_stored :comments

  def self.summary
    record = new
    [record.tags, record.labels, record.posts, record.comments]
  end
end
