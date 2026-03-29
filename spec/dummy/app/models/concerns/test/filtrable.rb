# frozen_string_literal: true

module Test::Filtrable
  extend ActiveSupport::Concern

  included do
    scope :pinned, -> { where(pinned: true) }
    scope :unpinned, -> { where(pinned: false) }
  end

  def filtrable?
    created_at.present? && updated_at.present?
  end

  def teste
    asdasd + adddd
  end
end
