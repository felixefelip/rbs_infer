# frozen_string_literal: true

module Post::Notifiable
  extend ActiveSupport::Concern

  included do
    delegate :updated_at, to: :user, prefix: true

    # The dominant Rails shape for a lifecycle callback, and the one
    # `.steep_callbacks.yml` used to miss entirely: the macro in the concern's
    # `included do`, the handler in the concern's body (felixefelip/rbs_rails#19).
    #
    # The callback runs on the HOST, so the record is past its validations and
    # `user` — a required `belongs_to` — is non-nil. The handler is type-checked
    # in the CONCERN, so the entry is keyed `Post::Notifiable` while the
    # narrowing it applies is the host's `Post & Post::Validated`.
    #
    # `notification_payload` above is the control: the same `user.full_name`,
    # reached from no callback, and it still reports `(::User | nil)` in the
    # baseline. Only what the callback reaches is narrowed.
    after_create_commit :notify_author_followers
  end

  def notification_title
    "[#{status.text}] #{title}"
  end

  def notify_subscribers(subscribers)
    subscribers.each do |subscriber|
      deliver_notification(subscriber)
    end
  end

  def notification_excerpt(length = 140)
    body.to_s.truncate(length)
  end

  def notification_payload
    {
      post_id: id,
      title: title,
      author_name: user.full_name,
      published_at: published_at&.iso8601,
      excerpt: notification_excerpt
    }
  end

  private

  def deliver_notification(subscriber)
    EmailNotifier.new.notify(user, "post_notification")
  end

  # The callback handler. Nothing calls it in the source — Rails does, by
  # symbol — so the narrowing can only come from the sidecar entry.
  def notify_author_followers
    author_digest_subject
  end

  # One hop past the handler: reachable only through it, so it is the transitive
  # self-call closure that carries the narrowing this far.
  def author_digest_subject
    "#{user.full_name}: #{title}"
  end
end
