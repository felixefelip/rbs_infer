# The path Active Record's options take from `has_many` to `association_class`
# (felixefelip/rbs_infer#392, item 6), one step per pair of callers:
#
#   - Stored: the options are kept in the reflection (`@options`)
#     and read back through its reader, the way
#     `HasManyReflection#association_class` reads `options[:through]`.
#   - Keywords: the macro takes them as `**options`, so the hash is built by
#     the call's keywords, not written as a literal.
#   - Normalized: the constructor passes them through a method that deletes a
#     key before storing them, like `normalize_options` deletes `:counter_cache`.
#   - Autosaved: a method of the reflection writes a key once they are stored,
#     like `autosave=` writes `@options[:autosave]`, and is called on it.
#
# In each pair, the caller passing `through:` is a `Through` class and the
# other a `Plain` class.
#
# The reader is called `options`, as Active Record calls it, and `Statuses`
# hands another class's `options` on: a reader's uses count by the class their
# receiver is typed as (felixefelip/steep#300).
#
# Nothing here states a type.
module Example96
  class Plain; end
  class Through; end

  class Reflection
    attr_reader :name, :options

    def initialize(name, options)
      @name = name
      @options = options
    end

    def association_kind
      options[:through] ? Through : Plain
    end
  end

  class NormalizedReflection
    attr_reader :name, :options

    def initialize(name, options)
      @name = name
      @options = without_counter_cache(options)
    end

    def association_kind
      options[:through] ? Through : Plain
    end

    private

    def without_counter_cache(options)
      options.delete(:counter_cache)
      options
    end
  end

  class AutosavedReflection < NormalizedReflection
    def autosave=(autosave)
      @options[:autosave] = autosave
    end
  end

  class Builder
    def self.stored(name, options) = Reflection.new(name, options)
    def self.with_keywords(name, **options) = Reflection.new(name, options)
    def self.normalized(name, **options) = NormalizedReflection.new(name, options)

    def self.autosaved_kind(name, **options)
      reflection = AutosavedReflection.new(name, options)
      reflection.autosave = true
      reflection.association_kind
    end
  end

  class Statuses
    def self.listed = Kernel.puts(Post.status.options)
  end

  class Tags
    def self.stored_through = Builder.stored(:posts, { through: :taggings }).association_kind
    def self.stored_plain = Builder.stored(:taggings, {}).association_kind

    def self.keywords_through = Builder.with_keywords(:posts, through: :taggings).association_kind
    def self.keywords_plain = Builder.with_keywords(:taggings).association_kind

    def self.normalized_through = Builder.normalized(:posts, through: :taggings).association_kind
    def self.normalized_plain = Builder.normalized(:taggings, counter_cache: true).association_kind

    def self.autosaved_through = Builder.autosaved_kind(:posts, through: :taggings)
    def self.autosaved_plain = Builder.autosaved_kind(:taggings, counter_cache: true)
  end
end
