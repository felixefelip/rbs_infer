# frozen_string_literal: true

# The element of the `has_many :notifications` that `User` gets from
# `User::Notifiable` rather than from its own class body. Nothing here is
# special — the point of the fixture is entirely on the owner's side.
class Notification < ApplicationRecord
  belongs_to :user

  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }

  # `store_accessor` defines its pair with `define_method` inside a module it
  # includes, so nothing about `channel`/`theme`/`settings_digest` is statically
  # visible: without the AR-runtime pseudo-code every read below is a `NoMethod`,
  # and the `super` in the override has no super method to reach.
  #
  # The store COLUMN is deliberately absent from the schema. The pseudo-code
  # models the slot as an ivar and never reads the column, so the fixture needs no
  # migration — and its absence is what proves the pairs come from the macro
  # rather than from rbs_rails' column accessors.
  store_accessor :settings, :channel, :theme
  store_accessor :settings, :digest, prefix: true

  # The override the included module makes possible. It types only because the
  # writer below pins the slot: `super` alone is the reader, and a store key that
  # was never written is nil.
  def channel
    super || "email"
  end

  # The call site the slot's type comes from — inference reads assignments, not
  # annotations, so a key nobody writes stays untyped however it is read.
  def mute!
    self.channel = "none"
  end

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
