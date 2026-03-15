# frozen_string_literal: true

class User < ApplicationRecord
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
end
