# frozen_string_literal: true

class PostPublisher
  attr_reader :post, :notifier

  def initialize(post, notifier: EmailNotifier.new)
    @post = post
    @notifier = notifier
  end

  def call
    return false if post.published?

    post.publish!
    notifier.notify(post.user, "Your post '#{post.title}' has been published!")
    true
  end

  def self.publish(post)
    new(post).call
  end
end
