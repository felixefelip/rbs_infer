# frozen_string_literal: true

class Tag < ApplicationRecord
  has_many :post_tags, dependent: :destroy
  has_many :posts, through: :post_tags

  validates :name, presence: true, uniqueness: true

  def self.popular(limit = 10)
    joins(:post_tags)
      .group(:id)
      .order("COUNT(post_tags.id) DESC")
      .limit(limit)
  end
end
