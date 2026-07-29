# frozen_string_literal: true

# The element of the `has_many :notifications` that `User` gets from
# `User::Notifiable` rather than from its own class body. Nothing here is
# special — the point of the fixture is entirely on the owner's side.
class Notification < ApplicationRecord
  belongs_to :user

  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }

  def read?
    read_at.present?
  end

  # Guarded like `Comment#display_body`: the column is `null: false` and
  # validated, so `title` is non-nil only on `Notification & Validated` — a bare
  # deref here is a `String?` error, not a fixture of this issue.
  def headline
    return "" unless title

    title.upcase
  end
end
