# frozen_string_literal: true

class Post < ApplicationRecord
  extend Enumerize

  belongs_to :user
  has_many :comments, dependent: :destroy
  has_many :post_tags, dependent: :destroy
  has_many :tags, through: :post_tags

  enumerize :status, in: [:draft, :published, :archived], default: :draft, predicates: true, scope: :shallow
  enumerize :priority, in: [:low, :medium, :high]

  validates :title, presence: true
  validates :body, presence: true

  def summary(length = 100)
    body.to_s.truncate(length)
  end

  def test_status
    status
  end

	def was_archived?
		status.archived?
	end

  def creator
    user
  end

  def author_name
    user.full_name
  end

  def publish!
    update!(published: true, published_at: Time.current)
  end

  def comments_count
    comments.count
  end

  def add_comment(author:, body:)
    comments.create!(user: author, body: body)
  end
end
