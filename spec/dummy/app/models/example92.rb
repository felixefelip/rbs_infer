# example85 in the shape `ActiveSupport::Inflector` has it — felixefelip/steep#247,
# the stateful row of felixefelip/steep#209:
#
#   - the inflector is a module, and its rules object is built and filled in one
#     memo, `Rules.new.tap { … }`, which nothing in the module body calls;
#   - the rules are walked by `Rules#apply`, inside the object that holds them;
#   - the macro that asks for a singular is another class's.
#
# The checker folds this shape (felixefelip/steep#247): with the signatures it
# needs, `has_many_like :posts` and `has_many_like :categories` define
# `post_ids` and `category_ids`. Two of those signatures are still missing here,
# so both calls record a hole and `summary` reports `post_ids`/`category_ids` as
# undefined:
#
#   - `Rules#apply`'s parameter reads `untyped`: its one call site has the memo
#     as receiver, `inflections.apply(word)`, and a call site's receiver is not
#     resolved when it is a call with none of its own (#439);
#   - `self.@inflections` is not declared: a memo whose value is a call with a
#     block declares no ivar (#440).
#
# Nothing here states a type.
module Example92
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
    def self.inflections
      @inflections ||= Rules.new.tap do |inflect|
        inflect.singular(/s\z/, "")
        inflect.singular(/ies\z/, "y")
      end
    end

    def self.singularize(word) = inflections.apply(word)
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
