# Rules accumulated in an object at load time and applied in another method —
# felixefelip/steep#205, stage 3 (felixefelip/steep#209, item 3).
#
# `ActiveSupport::Inflector.singularize`, cut down to its shape:
#
#   - one `Rules` instance per class, memoized at the class level
#     (`Inflections.instance` is `@__instance__[locale] ||= new`);
#   - the class body adds rules with `singular`, each one PREPENDED, so the
#     last rule written is tried first;
#   - `singularize` walks them and stops at the first `sub!` that changes the
#     word.
#
# The order is load-bearing: tried in the order written, "categories" would
# lose its "s" first and come out "categorie".
#
# The class body is followed statement by statement, as Ruby runs it. The
# memo builds the one `Rules` the class holds (felixefelip/steep#240); each
# `singular` call is checked under what that object holds and leaves
# `@singulars` one rule longer (felixefelip/steep#242); `has_many_like`, and the
# `singularize` it calls, are checked under the rules as they stand there; and
# the walk is run one rule at a time, stopping at the first that matches
# (felixefelip/steep#239). So `post_ids` and `category_ids` are defined, per
# call site. A caller that runs before the rules are written does not get
# "post": the answer belongs to the state, not to the argument.
#
# Nothing here states a type.
class Example85
  class Rules
    attr_reader :singulars

    def initialize
      @singulars = []
    end

    def singular(rule, replacement)
      @singulars.prepend([rule, replacement])
    end
  end

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
