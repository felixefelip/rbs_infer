# frozen_string_literal: true

class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # ActiveRecord after-validation callback: it runs in `after_save`, so the
  # record satisfies its presence validations and `self` is
  # `Comment & Comment::Validated` — `post` (a required belongs_to) is non-nil
  # here. rbs_rails emits an `applies_self` callback entry and Steep refines
  # `self` at this method's entry, so `post.author_name` typechecks without a
  # nil-guard (no `(Post | nil)` error).
  after_save :notify_post_author

  def author_name
    user.name
  end

  def short_body(max = 50)
    body.truncate(max)
  end

  def create_custom
    Create.new.create(id)
  end

  # Satisfying call sites: guard the precondition (self.user / self.body
  # not-nil) before invoking the contracted method, so Contracts::Enforcement
  # marks the contract enforced and the body narrowing applies. The guard
  # returns a non-nil default so the helper's own inferred type stays
  # consistent (no implicit nil return path).
  def display_author
    return "anonymous" unless user

    author_name
  end

  def display_body
    return "" unless body

    short_body
  end

  def notify_post_author
    post.author_name
  end

  # The same precondition, read through a local: `_ = user` IS `self.user`,
  # which is how ActiveSupport's `delegate` writes its body (`_ = user;
  # _.email(...)`). The deref through `_` is rooted at `self.user`, so the
  # method requires it non-nil and the body narrows.
  def author_full_name
    _ = user
    _.full_name
  end

  # A validated comment establishes it: `last!` returns
  # `Comment & Comment::Validated`, whose `user` is non-nil.
  def self.latest_author_full_name
    comment = Comment.last!
    comment.author_full_name
  end
end
