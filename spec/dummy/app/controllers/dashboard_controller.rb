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
# and `current_account` is non-nil from this one, which is why neither `@account` nor the
# `Current.user` read in the view needs a nil check.
#
# `set_current_account` runs AFTER the guard, so `current_account` is proven present at
# its entry and `Current.account` is proven populated from there on — including inside the
# view `show` renders. That chain used to be pre-derived into a `.steep_callbacks.yml` by
# `Rails::CurrentAttributesCallbacksGenerator`; it now falls out of the ordinary
# const-write postcondition, which is what makes this controller that generator's test.
class DashboardController < ApplicationController
  before_action :authenticate_account!
  before_action :set_current_account

  def show
    @account = current_account
    @recent_posts = Post.order(created_at: :desc).limit(5)
  end

  private

  def set_current_account
    Current.account = current_account
  end
end
