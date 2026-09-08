# frozen_string_literal: true

# The `perform_later` fixture: a job whose arguments exist ONLY at its enqueue
# site (`PostsController#publish`), which is the shape the ActiveJob runtime
# sidecar exists for. A human reads `AuthorDigestJob.perform_later(@post,
# recipient: @post.user.email)` and knows `post` is a `Post & Post::Validated`
# and `recipient` a `String`.
#
# It does not infer them yet — the sidecar's forward lives on `ActiveJob::Base`,
# shared by every job, so the evidence lands on that class's `*args` instead of
# here. The expectation pins the gap; the PR that closes it is the one that
# changes this file's RBS.
class AuthorDigestJob < ApplicationJob
  def perform(post, recipient:)
    {
      to: recipient,
      subject: post.notification_title,
      excerpt: post.notification_excerpt
    }
  end
end
