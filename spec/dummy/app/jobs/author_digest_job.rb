# frozen_string_literal: true

# The `perform_later` fixture: a job whose arguments exist ONLY at its enqueue
# site (`PostsController#publish`), which is the shape the ActiveJob runtime
# sidecar exists for. `perform` is typed from
# `AuthorDigestJob.perform_later(@post, recipient: @post.user.email)`: the
# forward on `ActiveJob::Base` is read as a call site of this class's `perform`,
# keeping the receiver (felixefelip/rbs_infer#331).
class AuthorDigestJob < ApplicationJob
  def perform(post, recipient:)
    {
      to: recipient,
      subject: post.notification_title,
      excerpt: post.notification_excerpt
    }
  end
end
