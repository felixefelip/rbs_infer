# frozen_string_literal: true

class Post < ApplicationRecord
  include Post::Taggable
  include Post::Notifiable
  include Test::Filtrable

  extend Enumerize

  belongs_to :user
  has_many :comments, dependent: :destroy
  has_many :post_tags, dependent: :destroy
  has_many :tags, through: :post_tags

  enumerize :status, in: [:draft, :published, :archived], default: :draft, predicates: true, scope: :shallow
  enumerize :priority, in: [:low, :medium, :high]
  enumerize :category, in: { tech: 1, lifestyle: 2, travel: 3, food: 4 }, default: :tech, scope: :shallow

  validates :title, presence: true
  validates :body, presence: true

  delegate :email, to: :user, prefix: true
  delegate :full_name, to: :user
  delegate :created_at, to: :user, prefix: true
  delegate :name, to: :tag, allow_nil: true

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

  def was_priority_high
	  priority&.high?
  end

  def publish_in_transaction
    ActiveRecord::Base.transaction do
      publish!
      self
    end
  end

  def iterate_tags
    my_tags = tags.order(:name)
    my_tags.each do |tag|
      puts tag.name
    end
  end

  def test_enumerize_status
    Post.status
  end

  def test_enumerize_status_options
    Post.status.options
  end
end
