# frozen_string_literal: true

module PostsHelper
  def post_status_badge(post)
    css_class = case post.status.to_s
                when "published" then "bg-success"
                when "archived" then "bg-secondary"
                else "bg-warning"
                end

    content_tag(:span, post.status.to_s.capitalize, class: "badge #{css_class}")
  end

  def post_summary(post, length = 150)
    content_tag(:p, post.summary(length), class: "text-muted")
  end

  # Regression fixture (#46): an optional param defaulting to a value
  # constant must take the constant's VALUE type, not its bare name (which
  # is invalid RBS for a value constant). `Palette::WEIGHTS` is `Array[Integer]`
  # and `Coupon::CODE_LENGTH` is `Integer` — both resolved cross-file via the
  # RBS env. A class/module default (`Palette`) is the class object, so it
  # takes the `singleton(Palette)` type.
  def post_weights(weights = Palette::WEIGHTS, length = Coupon::CODE_LENGTH, klass = Palette)
    content_tag(:p, "#{weights.sum} #{length} #{klass}")
  end

  # Helper called ONLY from `posts/index.html.erb` inside the
  # `@posts.each |post|` block. Regression fixture for the
  # ivar/local name-collision bug — the param `post` here must be
  # inferred from the block element (`Post & Post::Validated`), not
  # from the controller's `@post` declaration (the wide union).
  def post_index_marker(post)
    content_tag(:span, post.title, class: "post-marker")
  end

  # Helper called ONLY from a PARTIAL (`posts/_comment.html.erb`). Regression
  # fixture for the mixin chain that runs through RBS: a partial's generated
  # class includes `ActionViewContext` and nothing else, and it is
  # `ActionViewContext` — emitted as `.rbs`, so absent from the source corpus —
  # that carries `PostsHelper`. Reading the include chain from source alone
  # stopped one link short, the partial was swept as a caller of nothing, and
  # this parameter came out `untyped` while Steep typed the very same argument
  # `Comment & Comment::Validated`.
  #
  # The pair with `post_index_marker` above is the point: that one is reached
  # from a non-partial view, whose class DOES write `include PostsHelper`. If
  # only this one regresses, the RBS half of the chain broke.
  def comment_author_badge(comment)
    content_tag(:span, comment.author_name, class: "comment-badge")
  end
end
