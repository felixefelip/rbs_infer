# Rules kept per locale in a `Concurrent::Map`, as Active Support keeps its
# inflections (`@__instance__ = Concurrent::Map.new`,
# `@__instance__[locale] ||= new`; felixefelip/rbs_infer#503).
#
# The same road as example85, with the memo a gem's object instead of a hash
# literal. The map's methods are concurrent-ruby's own source, the files the
# concurrent runtime generator brings into the program: on MRI `[]` reads the
# backend hash and `[]=` writes it inside `@write_lock.synchronize { super }`.
#
# Nothing here states a type.
class Example104
  class Rules
    attr_reader :singulars

    def initialize
      @singulars = []
    end

    def singular(rule, replacement)
      @singulars.prepend([rule, replacement])
    end
  end

  @rules_by_locale = Concurrent::Map.new

  def self.rules(locale = :en)
    @rules_by_locale[locale] ||= Rules.new
  end

  rules.singular(/s\z/, "")
  rules.singular(/ies\z/, "y")

  def self.singularize(word)
    result = word.dup
    rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
    result
  end

  def self.has_many_like(name)
    class_eval "def #{singularize(name.to_s)}_ids; []; end"
  end

  has_many_like :posts
  has_many_like :categories

  def self.summary
    record = new
    [record.post_ids, record.category_ids]
  end
end
