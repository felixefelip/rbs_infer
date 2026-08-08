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

    # A `class << self` method with a TYPED return — `popular` resolves to
    # `untyped` on its own, so it cannot tell a delegation that resolved from
    # one that silently fell back. This is the exact shape of the issue's
    # `Filter.from_params` (felixefelip/rbs_infer#185).
    def default_limit
      10
    end

    # A parameter with NO default, so its type can only come from a call site —
    # and the only caller (`Post#tag_named`) goes through the has_many proxy, two
    # ancestry links away from this class. Both halves of the chain are under
    # test: the proxy's receiver type has to be recognized as reaching
    # `Tag::GeneratedRelationMethods#named`, and the pseudo-code's
    # `::Tag.named(value)` then has to carry that type here.
    def named(value)
      find_by(name: value)
    end
  end
end
