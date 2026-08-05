# frozen_string_literal: true

# felixefelip/rbs_infer#183 — `initialize` assigns its ivars on one line.
#
# Prism shapes `@a, @b = a, b` as a single `MultiWriteNode` whose targets are
# `InstanceVariableTargetNode`s, so every visitor keyed on
# `InstanceVariableWriteNode` used to miss it: the params were typed from the
# call-site as usual, but the attrs came out `untyped` (and, once the ivar link
# was restored, `T?` until the definite-initialization rule learned the shape
# too). Fizzy's `User::Filtering` is this class.
class PostFiltering
  attr_reader :user, :post, :expanded

  def initialize(user, post, expanded: false)
    @user, @post, @expanded = user, post, expanded
  end

  def expanded?
    @expanded
  end

  def title
    post.title
  end

  # `user` is nilable because the call-site passes `@post.user` — nothing to do
  # with the multiple assignment, which is what this fixture is about.
  def author_name
    user&.name
  end
end
