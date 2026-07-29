# frozen_string_literal: true

class User < ApplicationRecord
  include User::Recoverable
  include User::Displayable
  # Contributes `has_many :notifications` — declared only in the concern's
  # `included do`, never here (felixefelip/rbs_infer#139).
  include User::Notifiable

  mount_uploader :avatar, AvatarUploader

  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
  scope :by_name, ->(name) { where(name: name) }

  attr_accessor :session_token

  def full_name
    "#{first_name} #{last_name}"
  end

  def active?
    active
  end

  def posts_count
    posts.count
  end

  def recent_posts(limit = 5)
    posts.order(created_at: :desc).limit(limit)
  end

  # Called from ONE place: dashboard/show.html.erb, on a `Current.user` receiver,
  # inside `@recent_posts.each do |post|`. Both halves of that call site used to be
  # invisible (felixefelip/rbs_infer#131) — the template never spells `User`, so it
  # was not a candidate caller, and `Current.user` is nilable, so its type never
  # matched the target. `post` is typed here only because both were fixed.
  def posts_titled_like(post)
    posts.where(title: post.title).count
  end

  # The same deref as in `User::Notifiable`, but from the HOST body — the getter
  # has to be on `User`, not on the concern, which is where the runtime puts it.
  def unread_notifications_count
    notifications.unread.count
  end
end
