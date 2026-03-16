# frozen_string_literal: true

class AddCategoryToPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :posts, :category, :integer
  end
end
