# frozen_string_literal: true

# felixefelip/rbs_infer#139. The association is declared HERE and nowhere else —
# `user.rb` only writes `include User::Notifiable`. That is the ordinary Rails
# shape (it is where fizzy's `has_many :notifications` lives), and it used to be
# invisible to the AR-runtime generator: rbs_rails reflects at runtime, where the
# concern is already included, but this generator reads source, and reading
# `user.rb` alone found no `has_many` at all. No getter, no proxy reopen, and
# `user.notifications` came out with no type.
#
# The methods below are the assertion. Each derefs the association by its bare
# name from inside the concern — the type they get can only come from the getter
# the generator now emits on `User`, so a regression shows up as an error on
# these lines rather than as a silently missing file.
module User::Notifiable
  extend ActiveSupport::Concern

  included do
    has_many :notifications, dependent: :destroy
  end

  def unread_notifications
    notifications.unread
  end

  def notifications_count
    notifications.count
  end

  # Construction through the proxy: `build` sets the inverse `belongs_to :user`
  # from the owner, so the record is complete before `save` — the flow the proxy
  # reopen models.
  def notify!(title)
    notifications.create!(title: title)
  end

  # The call site that pins `notify!`'s parameter — inference reads arguments,
  # not annotations, so a method nobody calls stays `untyped`.
  def notify_welcome!
    notify!("Welcome")
  end

  def latest_notification_headline
    latest = notifications.order(created_at: :desc).first
    return nil unless latest

    latest.headline
  end
end
