# The cache example109's `compute_type` reads, reached the way
# `Post.new.comments` reaches it: `Base.inherited` gives each subclass its own
# `@types`, and `App.run` builds a `Post`, whose `reflection` keeps the class
# in an ivar of another object, which looks the name up through it. The
# lookup finds `@types` empty and answers the name it builds.
#
# Nothing here states a type.
module Example126
  class Base
    def self.inherited(subclass)
      super
      subclass.instance_variable_set(:@types, {})
    end

    # Expected: ("Comment" name) -> "Example126::Comment"
    def self.lookup(name)
      found = @types[name]
      return found if found

      value = "Example126::#{name}"
      @types[name] = value
      value
    end

    # Expected: () -> Example126::Reflection
    def reflection = Reflection.new(self.class)
  end

  class Reflection
    # Expected: (singleton(Example126::Post) owner) -> void
    def initialize(owner)
      @owner = owner
    end

    # Expected: () -> "Example126::Comment"
    def klass = @owner.send(:lookup, "Comment")
  end

  class Post < Base
  end

  class App
    # Expected: () -> "Example126::Comment"
    def self.run = Post.new.reflection.klass
  end
end
