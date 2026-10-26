# The whole road `ActiveSupport::Inflector.singularize` takes to its rules,
# written in plain Ruby the way Active Support and i18n write it
# (felixefelip/steep#354, the fallback walk of felixefelip/steep#265):
#
#   - one rules object per locale, in a class-level hash
#     (`@__instance__[locale] ||= new`, felixefelip/steep#347);
#   - the rules written through a block the inflector yields the locale's
#     object to (`inflections(:en) { |inflect| … }`, felixefelip/steep#349);
#   - read back through a walk of the locale's fallback chain that returns
#     the first rules object the hash holds (`instance_or_fallback`,
#     felixefelip/steep#351, #352, #353);
#   - the chain is a hash's own keyed memo, `super || store(locale,
#     compute(locale))` (`I18n::Locale::Fallbacks#[]`, felixefelip/steep#354).
#
# `has_many_like :posts` and `has_many_like :categories` define `post_ids`
# and `category_ids` on `Post`, a class of its own that reaches the rules
# through `Inflector.singularize`, as a model reaches Active Support's
# (felixefelip/steep#362).
#
# Nothing here states a type.
module Example102
  class Rules
    attr_reader :singulars

    def initialize
      @singulars = []
    end

    def singular(rule, replacement)
      @singulars.prepend([rule, replacement])
    end

    def apply(word)
      result = word.dup
      @singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
      result
    end
  end

  class FallbackChains < Hash
    def initialize
      @default = :en
    end

    def [](locale)
      locale = locale.to_sym
      super || store(locale, compute(locale))
    end

    def compute(locale) = [locale, @default]
  end

  module Locales
    def self.fallback_chains = @fallback_chains ||= FallbackChains.new
  end

  class Inflector
    def self.locale_rule_sets = @locale_rule_sets ||= {}
    def self.rule_set_for(locale) = (locale_rule_sets[locale] ||= Rules.new)

    def self.with_rules(locale)
      yield rule_set_for(locale) if block_given?
    end

    def self.rules_or_fallback(locale)
      Locales.fallback_chains[locale].each do |candidate|
        return locale_rule_sets[candidate] if locale_rule_sets.key?(candidate)
      end
      rule_set_for(locale)
    end

    def self.singularize(word) = rules_or_fallback(:en).apply(word)

    with_rules(:en) do |rules|
      rules.singular(/s\z/, "")
      rules.singular(/ies\z/, "y")
    end
  end

  class Post
    def self.has_many_like(name)
      class_eval "def #{Inflector.singularize(name.to_s)}_ids; []; end"
    end

    has_many_like :posts
    has_many_like :categories

    def self.summary
      record = new
      [record.post_ids, record.category_ids]
    end
  end
end
