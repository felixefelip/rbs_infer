# frozen_string_literal: true

# Companion to app/models/assignment.rb — the runtime-safe construction path,
# mirroring Fizzy's `Boards::ColumnsController#create` (`@board.columns.create!`).
#
# An Assignment is only ever built through `@post.assignments`, so `post` is
# already set when the `belongs_to :owner, default: -> { post.user }` lambda
# runs in `before_validation`. That is exactly why the Steep `(::Post | nil)`
# error on the default lambda is a false positive: at runtime `post` is never
# nil at that point.
class Posts::AssignmentsController < ApplicationController
  before_action :set_post

  def create
    @assignment = @post.assignments.create!(assignment_params)
    redirect_to @post, notice: "Assignment created."
  end

  private

  def set_post
    @post = Post.find(params[:post_id])
  end

  def assignment_params
    params.require(:assignment).permit(:owner_id)
  end
end
