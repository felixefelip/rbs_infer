# frozen_string_literal: true

# Consumer of the Devise auth layer, kept OUT of ApplicationController on purpose: the
# `before_action :authenticate_account!` is declared here, so the session-based
# `authenticate_user` chain every other controller inherits is untouched and this is the
# only place the two layers stack.
#
# What that stacking pins down: the controller runner inlines the inherited chain
# (`authenticate_user`, then `log_user_author_name if current_user_present?`) AND this
# controller's own guard, each followed by its halt check — so both layers' facts have to
# survive to the action. Inside `show`, `Current.user` is non-nil from the inherited guard
# and `current_account` is non-nil from this one (the Devise callbacks sidecar narrows
# `self` with the `AccountAuthenticated` marker), which is why neither `@account` nor the
# `Current.user` read in the view needs a nil check.
class DashboardController < ApplicationController
  before_action :authenticate_account!

  def show
    @account = current_account
    @recent_posts = Post.order(created_at: :desc).limit(5)
  end
end
