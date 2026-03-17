# frozen_string_literal: true

class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def author_name
    user.name
  end

  def short_body(max = 50)
    body.truncate(max)
  end

  def create_custom
    Create.new.create(id)
  end
end
