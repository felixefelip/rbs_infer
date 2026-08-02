# frozen_string_literal: true

# Mirrors Fizzy's `Card::Entropy`: a plain class whose one entry point takes the
# record a concern hands it, so its parameter type is exactly as good as the
# `self` that concern resolves to.
#
# `published_at` is the HOST's column and `tag_names` is the CONCERN's method,
# so only `Post & Post::Taggable` has both — the lexical answer `Post::Taggable`
# is missing half of what the body already uses (felixefelip/rbs_infer#161).
class Post::TagDigest
  class << self
    def for(post)
      return unless post.published_at

      new(post.title, post.tag_names)
    end
  end

  def initialize(title, tag_names)
    @title = title
    @tag_names = tag_names
  end

  def headline
    "#{@title} (#{@tag_names.size})"
  end
end
