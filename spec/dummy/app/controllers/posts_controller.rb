# frozen_string_literal: true

class PostsController < ApplicationController
  before_action :set_post, only: %i[show edit update destroy publish]

  def index
    @posts = Post.published.order(created_at: :desc)
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
    params.require(:post).permit(:title, :body, :published)
  end
end
