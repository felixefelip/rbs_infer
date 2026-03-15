# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    @users = User.active.order(:name)
  end

  def show
    @user = User.find(params[:id])
    @posts = @user.recent_posts
  end
end
