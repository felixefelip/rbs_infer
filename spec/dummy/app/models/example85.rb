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
# Today `@singulars` is an array the checker knows only by element type, so
# the walk has no passes to check one by one. The block is widened before it is
# entered (felixefelip/steep#214), `singularize` is `String`, and `post_ids` and
# `category_ids` are never defined. Closing it needs the list's contents
# carried in the object's state, the object identified by where it was built
# (felixefelip/steep#216), and the state fixed once the class body has run.
#
# Also pinned as it stands: `singular`'s parameters read `untyped`, though both
# call sites in the class body pass a `Regexp` and a `String`.
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
