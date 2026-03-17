# frozen_string_literal: true

module User::Recoverable
  extend ActiveSupport::Concern

  included do
    scope :inactive, -> { where(active: false) }
  end

  def deactivate!
    update!(active: false)
  end

  def reactivate!
    update!(active: true)
  end

  def toggle_active!
    update!(active: !active)
  end

  def days_since_last_post
    last_post = posts.order(created_at: :desc).first
    return nil unless last_post

    ((Time.current - last_post.created_at) / 1.day).to_i
  end

  def dormant?(threshold_days = 90)
    days = days_since_last_post
    return true if days.nil?

    days > threshold_days
  end
end
