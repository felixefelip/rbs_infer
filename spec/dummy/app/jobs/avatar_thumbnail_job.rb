# frozen_string_literal: true

# The second `perform_later` fixture, and the reason there are two: its arguments
# share nothing with `AuthorDigestJob`'s. One job is enqueued with a `Post` and a
# `String`, this one with a `User` and an `Array[Integer]`, from a different
# controller — so what lands on `ActiveJob::Base.perform_later`'s `*args` is the
# union of two unrelated jobs' signatures, which no single `perform` could ever
# accept.
#
# That union IS the limitation, stated in RBS: the forward lives on the shared
# base class, so it cannot tell which job a call site meant.
class AvatarThumbnailJob < ApplicationJob
  def perform(user, sizes:)
    sizes.map do |size|
      { owner: user.name, width: size }
    end
  end
end
