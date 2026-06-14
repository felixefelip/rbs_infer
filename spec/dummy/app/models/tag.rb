# frozen_string_literal: true

class Tag < ApplicationRecord
  has_many :post_tags, dependent: :destroy
  has_many :posts, through: :post_tags

  validates :name, presence: true, uniqueness: true

  # `class << self` form (instead of `def self.popular`): both must yield
  # the same `def self.popular` singleton method in the generated RBS. A
  # regression that mis-collected singleton-class methods as instance
  # methods would surface here as a `def popular:` instance member.
  class << self
    def popular(limit = 10)
      joins(:post_tags)
        .group(:id)
        .order("COUNT(post_tags.id) DESC")
        .limit(limit)
    end
  end
end
