# frozen_string_literal: true

module Post::Notifiable
  extend ActiveSupport::Concern

	# @type self: singleton(Post) & singleton(Post::Notifiable)
	# @type instance: Post & Post::Notifiable

  included do
    delegate :updated_at, to: :user, prefix: true
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
end
