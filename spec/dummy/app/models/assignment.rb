# frozen_string_literal: true

# Reproduces the Fizzy `belongs_to :account, default: -> { board.account }`
# pattern with a real Active Record model.
#
# `owner` defaults to the post's user. But `post` is a (required) belongs_to,
# which rbs_rails types as `Post?` on the bare model, so Steep flags
# `post.user` inside the default lambda:
#
#   Type `(::Post | nil)` does not have method `user`
#
# — the exact `(::Board | nil) does not have method account` false positive from
# Fizzy. At runtime it never raises: the association's `default:` runs in
# `before_validation`, and the app only ever builds an Assignment through
# `post.assignments` (which sets `post`), so `post` is present when the lambda
# runs. `user` here plays the role of Fizzy's `account`.
class Assignment < ApplicationRecord
  belongs_to :post
  belongs_to :owner, class_name: "User", default: -> { post.user }

  before_validation :log_post_user_name

  # A predicate over a NILABLE AR receiver — `post` is `::Post?` here, exactly
  # the shape a `has_one` getter has. Rails short-circuits `Object#blank?`'s
  # `respond_to?(:empty?)` with a literal, so the RBS reads
  # `ActiveRecord::Core#present?: () -> true`; resolving only the non-nil branch
  # emitted `-> true` for a body that plainly returns false when `post` is nil,
  # and Steep rejected the very body it had typed as `(true | false)`.
  # `NilClass#present?: () -> false` is the other half, and the two together are
  # the whole of `bool`.
  def assigned?
    post.present?
  end

  private

  def log_post_user_name
    Rails.logger.info("Post user name: #{post.user.name.camelize}")
  end
end
