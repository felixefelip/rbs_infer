# frozen_string_literal: true

module Post::Taggable
  extend ActiveSupport::Concern

  included do
    has_many :post_tags, dependent: :destroy
    has_many :tags, through: :post_tags
  end

  def tag_names
    tags.pluck(:name)
  end

  def tag_with(name)
    tag = Tag.find_or_create_by!(name: name)
    post_tags.find_or_create_by!(tag: tag)
    tag
  end

  def untag(name)
    tag = Tag.find_by(name: name)
    post_tags.where(tag: tag).destroy_all if tag
  end

  def tagged_with?(name)
    tags.exists?(name: name)
  end

  def replace_tags(names)
    transaction do
      post_tags.destroy_all
      names.each { |name| tag_with(name) }
    end
  end
end
