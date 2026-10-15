# example92 with the rules registered the way `ActiveSupport::Inflector` registers
# them — felixefelip/steep#263, the stateful row of felixefelip/steep#209:
#
#   - the inflector module yields its rules object to a block,
#     `configure { |inflect| … }` (Active Support's `inflections`), only
#     `if block_given?`;
#   - the module body calls it with a block that writes the rules through
#     `inflect`;
#   - the rules are walked by `Rules#apply`, and the macro that asks for a
#     singular is another class's.
#
# The checker checks the block where it runs, at the `yield`
# (felixefelip/steep#263), so `has_many_like :posts` and
# `has_many_like :categories` define `post_ids` and `category_ids`.
#
# Nothing here states a type.
module Example93
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

  module Inflector
    def self.rule_set
      @rule_set ||= Rules.new
    end

    def self.configure
      yield rule_set if block_given?
    end

    def self.singularize(word) = rule_set.apply(word)

    configure do |inflect|
      inflect.singular(/s\z/, "")
      inflect.singular(/ies\z/, "y")
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
