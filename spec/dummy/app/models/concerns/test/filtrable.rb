# frozen_string_literal: true

module Test::Filtrable
  extend ActiveSupport::Concern

  included do
    scope :published, -> { where(published: true) }
    scope :drafts, -> { where(published: false) }
  end

  def filtrable?
    created_at.present? && updated_at.present?
  end

  def teste
    asdasd + adddd
  end
end
