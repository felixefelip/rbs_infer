# frozen_string_literal: true

class PostsController < ApplicationController
  include FilterConfiguration

  before_action :set_post, only: %i[show edit update destroy publish]

  def index
    filter = configure_filter("posts")
    @posts = Post.query_filter(filter).order(created_at: :desc)
  end

  def show
    @comments = @post.comments.recent
  end

  def new
    @post = Post.new
  end

  def create
    @post = Post.new(post_params)
    if @post.save
      redirect_to @post, notice: "Post created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @post.update(post_params)
      redirect_to @post, notice: "Post updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @post.destroy
    redirect_to posts_path, notice: "Post deleted."
  end

  def publish
    # Assignment call-site that types `Current.user` (rbs_infer#19)
    Current.user = @post.user
    build_filtering_for_current_user
    publisher = PostPublisher.new(@post)
    if publisher.call
      redirect_to @post, notice: "Post published."
    else
      redirect_to @post, alert: "Post could not be published."
    end
  end

  private

  def set_post
    @post = Post.find(params[:id])
  end

  def set_test
    @test = User.first!.posts.last
  end

  def post_params
    params.require(:post).permit(:title, :body, :pinned)
  end

  # The call-site that types `PostFiltering#initialize` — its one-line
  # `@user, @post, @expanded = ...` (felixefelip/rbs_infer#183) and, for the
  # `user` parameter, #186: `Current.user` is DECLARED nilable and
  # the guard proves it non-nil for the rest of the body. Taking the declaration
  # here handed the parameter a `nil` no call site can pass. Fizzy's
  # `FilterScoped` is this shape.
  def build_filtering_for_current_user
    return unless Current.user

    PostFiltering.new(Current.user, @post, expanded: false)
  end
end
