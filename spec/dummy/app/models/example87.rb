# A literal stored by an ancestor's `initialize`, read back in another method —
# felixefelip/steep#230 (felixefelip/steep#205, stage 1).
#
# example83 with the reflection split the way Active Record splits it.
# `MacroReflection#initialize` is the one that binds `@name`;
# `AssociationReflection` reaches it with a bare `super`, and
# `HasManyReflection` defines no `initialize` at all. So
# `HasManyReflection.new(:posts, …)` runs `MacroReflection#initialize` two
# levels up, and nothing else in the project writes `@name`.
#
# The object state is composed along the `initialize` chain `new` runs, read
# off the RBS: `HasManyReflection` inherits `AssociationReflection#initialize`,
# whose bare `super` hands `name` on at the same position to the
# `initialize` that binds it. So `HasManyReflection.new(:posts, {})` is
# `Example87::HasManyReflection{@name: :posts}`, `reflection.name` answers
# `:posts`, and `posts` and `comments` are defined.
#
# Also pinned as it stands: `MacroReflection#initialize`'s parameters and the
# `name` reader read `untyped`. The only call site is
# `HasManyReflection.new(name, options)`, and it reaches neither the inherited
# `initialize` nor the one a bare `super` forwards to.
#
# Two callers on purpose. With one, the closed world types the reader `:posts`,
# and the fold works by accident.
#
# Nothing here states a type.
class Example87
  class MacroReflection
    attr_reader :name

    def initialize(name, options)
      @name = name
      @options = options
    end
  end

  class AssociationReflection < MacroReflection
    def initialize(name, options)
      super
      @collection = false
    end
  end

  class HasManyReflection < AssociationReflection
  end

  # Writes on the class it is handed, as `define_accessors(model, reflection)`
  # does.
  module Writer
    def self.define_accessors(model, reflection)
      model.class_eval "def #{reflection.name}; :many; end"
    end
  end

  def self.has_association(name, options = {})
    Writer.define_accessors(self, HasManyReflection.new(name, options))
  end

  has_association :posts
  has_association :comments

  def self.summary
    record = new
    [record.posts, record.comments]
  end
end
