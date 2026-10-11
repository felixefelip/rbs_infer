# Rules one body writes, read by a macro another class's body calls —
# felixefelip/steep#246, the shape `has_many` has: the rules belong to a
# module (`ActiveSupport::Inflector`), and the macro runs in the model.
#
# `Inflector`'s body pushes its rules, as example85's does; what it leaves its
# memo holding is known to the code that runs after it. `has_many_like` is
# defined on `Base` and called from `Post`'s body, so it is checked under the
# rules as they stand there, and `singularize` under them in turn. So
# `comment_ids` and `category_ids` are defined, per call site.
#
# Still pinned as it stands: `Inflector`'s `self.@rules` is declared on
# `Example88` (felixefelip/rbs_infer#431).
#
# Nothing here states a type.
module Example88
  class Rules
    attr_reader :singulars

    def initialize
      @singulars = []
    end

    def singular(rule, replacement)
      @singulars.prepend([rule, replacement])
    end
  end

  module Inflector
    def self.rules
      @rules ||= Rules.new
    end

    rules.singular(/s\z/, "")
    rules.singular(/ies\z/, "y")

    def self.singularize(word)
      result = word.dup
      rules.singulars.each { |(rule, replacement)| break if result.sub!(rule, replacement) }
      result
    end
  end

  class Base
    def self.has_many_like(name)
      class_eval "def #{Inflector.singularize(name.to_s)}_ids; []; end"
    end
  end

  class Post < Base
    has_many_like :comments
    has_many_like :categories

    def self.summary
      record = new
      [record.comment_ids, record.category_ids]
    end
  end
end
