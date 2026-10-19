# The reflection Active Record keeps for an association lives under another
# name for most of its life (felixefelip/rbs_infer#392, item 6): the macro
# stores it in a class-level registry, the way `add_reflection` fills
# `_reflections`; a second macro reads it back and writes its options hash,
# the way `accepts_nested_attributes_for` calls `autosave = true` on what
# `_reflect_on_association` answers; and an instance method reads it back
# again to branch on `options[:through]`, the way `association_class` does.
#
# `autosave=` may have run on any reflection, so what a reflection's options
# hold under `:autosave` is not known, but `:through` is: no write touches it.
# So `Article#tags_kind` is `Through`, `Article#comments_kind` is `Plain`, and
# `Article#tags_source` is `:taggings` (felixefelip/steep#318).
#
# Nothing here states a type.
module Example100
  class Plain; end
  class Through; end

  class Reflection
    attr_reader :options

    def initialize(options)
      @options = options
    end

    def autosave=(autosave)
      @options[:autosave] = autosave
    end

    def association_kind = options[:through] ? Through : Plain
  end

  class Base
    def self.association_reflections
      @association_reflections ||= {}
    end

    def self.associate(name, **options)
      association_reflections[name] = Reflection.new(options)
    end

    def self.accept_nested(name)
      reflect_on(name).autosave = true
    end

    def self.reflect_on(name)
      association_reflections[name]
    end
  end

  class Article < Base
    associate :tags, through: :taggings
    associate :comments
    accept_nested :tags

    def tags_kind = self.class.reflect_on(:tags).association_kind
    def comments_kind = self.class.reflect_on(:comments).association_kind
    def tags_source = self.class.reflect_on(:tags).options[:through]
  end
end
