# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    @users = User.active.order(:name)
  end

  def show
    @user = User.find(params[:id])
    @posts = @user.recent_posts
  end

  # Renders ANOTHER controller's view by absolute path — the view lives under
  # `app/views/posts/`, not this controller's namespace. What it pins down: the
  # render dispatch is per controller, so `ERBPostsShow` gets a second call site
  # HERE (in `UsersController#render`, keyed `"posts/show"`) alongside
  # `PostsController#render`'s `:show`, and the two must not collapse into each
  # other. The ivars `posts/show.html.erb` reads are set right here, exactly as
  # a real action rendering a foreign template has to.
  def featured_post
    @post = Post.find(params[:post_id])
    @comments = @post.comments.recent
    render "posts/show"
  end
end
