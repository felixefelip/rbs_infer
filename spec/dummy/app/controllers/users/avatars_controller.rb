# frozen_string_literal: true

class Users::AvatarsController < ApplicationController
  before_action :set_user

  def edit; end

  def update
    if @user.update(avatar_params)
      redirect_to @user, notice: "Avatar updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = User.find(params[:user_id])
  end

  def avatar_params
    params.require(:user).permit(:avatar, :avatar_cache, :remove_avatar)
  end
end
