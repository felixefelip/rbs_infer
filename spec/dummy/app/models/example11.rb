class Example11
  class Post
    def title
      'Hello'
    end
  end

  # Stands in for a controller action: the only place that constructs the view,
  # and therefore the only source of the view's `post` type.
  class Caller
    def run
      Example11::View.new(post: Example11::Post.new)
    end
  end

  # Stands in for a generated ERB view class. Its `@post` is assigned FROM A
  # PARAMETER — the shape the view-runtime pseudo-code emits
  # (felixefelip/rbs_infer#109), and the shape any plain Ruby class uses when it
  # stores a constructor argument.
  class View
    def initialize(post:)
      @post = post
    end

    # A human reads `@post` here as `Example11::Post`: the only caller passes
    # `Post.new`, and nothing reassigns it. The analyzer now agrees at this CALL
    # SITE too, by reading the type off the class's own RBS.
    def render
      Example11::Partial.new(post: @post)
    end
  end

  # IVAR-ARGUMENT RESOLUTION. `Partial#initialize` infers
  # `(post: Example11::Post)` from the call site above.
  #
  # It used to infer `(post: untyped)`. `NewCallCollector#collect_class_ivar_types`
  # records an ivar only when it is assigned from a CallNode
  # (`@post = Post.new`, `@post = Foo.bar`); an ivar assigned from a PARAMETER —
  # the commonest shape there is, and the one the view-runtime pseudo-code emits —
  # was skipped, so `lookup_ivar_type` found nothing.
  #
  # The fact was never missing, only discarded: `Example11::View`'s own generated
  # RBS already declared `@post: Example11::Post`. The fix reads that back instead
  # of teaching the syntactic collector one more assignment shape — and resolves
  # it against the LEXICALLY ENCLOSING class, since the caller class tracked per
  # file names the outer `Example11`, whose RBS declares no `@post` at all.
  #
  # Note this gap was invisible to `steep check`: `untyped` absorbs every method
  # call, so nothing errored. The evidence is the generated RBS snapshot, which is
  # why this fixture is pinned by an integration expectation rather than by the
  # steep baseline.
  class Partial
    def initialize(post:)
      @post = post
    end

    private

    attr_reader :post
  end
end
