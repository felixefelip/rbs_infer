# frozen_string_literal: true

class ReplacePublishedWithPinnedOnPosts < ActiveRecord::Migration[8.0]
  def change
    remove_column :posts, :published, :boolean, default: false
    add_column :posts, :pinned, :boolean, default: false, null: false
  end
end
