# frozen_string_literal: true

module FilterConfiguration
  extend ActiveSupport::Concern

  def configure_filter(name)
    return {} if clean_filter?

    sanitize_filter
  end

  private

  def clean_filter?
    ActiveModel::Type::Boolean.new.cast(params[:clean_filter])
  end

  def sanitize_filter
    params.delete_if { |_, value| value.blank? }
  end
end
