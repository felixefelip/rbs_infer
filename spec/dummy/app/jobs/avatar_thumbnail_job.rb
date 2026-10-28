# frozen_string_literal: true

# The second `perform_later` fixture, and the reason there are two: its arguments
# share nothing with `AuthorDigestJob`'s. One job is enqueued with a `Post` and a
# `String`, this one with a `User` and an `Array[Integer]`, from a different
# controller. `ActiveJob::Base.perform_later`'s `*args` receives both, and
# rightly: every job is enqueued through it.
#
# Each `perform` must take only its own job's call site. A receiver filter too
# loose to tell the two jobs apart shows up here as one taking the other's
# arguments (felixefelip/rbs_infer#331).
class AvatarThumbnailJob < ApplicationJob
  def perform(user, sizes:)
    sizes.map do |size|
      { owner: user.name, width: size }
    end
  end
end
