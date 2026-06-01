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
end
