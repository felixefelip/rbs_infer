# frozen_string_literal: true

# The per-model half of the pair described in `concerns/commentable.rb`: it owns
# nothing but the re-export and the hook the shared concern has no business
# knowing about. `Post#comments_count` and `Post#add_comment` are the assertion —
# they only type if `has_many :comments` reached `Post` through both hops.
module Post::Commentable
  extend ActiveSupport::Concern

  include ::Commentable

  def commentable?
    published_at.present?
  end
end

class Post
  has_many :comments, dependent: :destroy
end
