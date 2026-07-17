class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :current_user

  before_action :authenticate_user
  before_action :log_user_author_name, if: :current_user_present?

  private

  def current_user
    User.find_by(id: session[:user_id])
  end

  def authenticate_user
    unless current_user
      redirect_to root_path
      return
    end

    current_user.full_name.camelize

    Current.user = current_user
  end

  def log_user_author_name
    Rails.logger.info "User #{Current.user.id}, full name: #{Current.user.name.camelize} accessed #{request.path}"
    Rails.logger.info "User full name: #{Current.author_name.camelize} accessed #{request.path}"
  end

  def current_user_present?
    Current.user.present?
  end
end
