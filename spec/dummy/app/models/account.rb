# frozen_string_literal: true

# The Devise scope of the dummy app (`devise_for :accounts` in config/routes.rb).
#
# Nothing Devise contributes is statically visible: `devise` mixes its modules in at
# class-definition time and `:validatable` installs its email/password validations at
# runtime, so neither rbs_rails nor rbs_infer sees a single `def` or `validates` from it.
# The scoped helpers (`current_account`, `authenticate_account!`, …) come from
# `RbsInfer::Extensions::Devise::Generator`, which reads the `devise_for` declaration.
#
# `validates :display_name` is ours, and it is the reason `Account::Validated` exists —
# the marker the generator decorates `current_account`'s proven type with.
class Account < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  validates :display_name, presence: true

  def label
    "#{display_name} <#{email}>"
  end
end
