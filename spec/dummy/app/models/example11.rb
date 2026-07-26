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
    # `Post.new`, and nothing reassigns it. The analyzer agrees at the CLASS
    # level — the generated RBS declares `@post: Example11::Post` — but not at
    # this CALL SITE.
    def render
      Example11::Partial.new(post: @post)
    end
  end

  # IVAR-ARGUMENT RESOLUTION gap. `Partial#initialize` should infer
  # `(post: Example11::Post)` from the call site above, but infers
  # `(post: untyped)`.
  #
  # Cause: `NewCallCollector#collect_class_ivar_types` records an ivar only when
  # it is assigned from a CallNode (`@post = Post.new`, `@post = Foo.bar`). An
  # ivar assigned from a PARAMETER is skipped, so `lookup_ivar_type` finds
  # nothing and the argument resolves to `untyped`.
  #
  # The fact is not missing — it is discarded. `Example11::View`'s own generated
  # RBS already declares `@post: Example11::Post`; the collector does not consult
  # it and re-derives with narrower logic. Swapping the assignment to
  # `@post = Example11::Post.new` makes this partial infer `Example11::Post`,
  # which isolates the cause to the assignment SHAPE, not to anything about the
  # call site.
  #
  # This blocks the view-RBS reformulation: every partial local depends on this
  # second hop, so all of them infer `untyped` until it resolves. Note the gap is
  # invisible to `steep check` — `untyped` absorbs every method call, so nothing
  # errors. The evidence is the generated RBS snapshot.
  class Partial
    def initialize(post:)
      @post = post
    end

    private

    attr_reader :post
  end
end
