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
# `set_current_account` runs AFTER the guard, so `current_account` is proven present at its
# entry, and since the handler cannot halt it establishes `Current.account` on every exit
# (felixefelip/steep#100). That fact reaches the action and the view `show` renders, which
# is why `Current.account.label` in dashboard/show.html.erb needs no nil check.
#
# Nothing asserts any of that. A sidecar used to (`Rails::CurrentAttributesCallbacks
# Generator`, removed in felixefelip/rbs_infer#125) by re-deriving the callback chain and
# scanning for a `Validated` marker; now the guard's own body, the finder's signature and
# the handler's own write are what prove it.
class DashboardController < ApplicationController
  before_action :authenticate_account!
  before_action :set_current_account
  before_action :set_current_viewer

  def show
    @account = current_account
    @recent_posts = Post.order(created_at: :desc).limit(5)
  end

  private

  def set_current_account
    Current.account = current_account
  end

  # Mirrors the shape a real app writes: a plain `before_action` (no halt) whose write
  # must ALSO prove what `Current#user=`'s override establishes transitively —
  # `author_name` and `viewer_name`. Under a HALTING guard that expansion already
  # happened, so the same write proved more or less depending on its neighbour
  # (felixefelip/steep#103).
  def set_current_viewer
    Current.user = current_user
  end
end
