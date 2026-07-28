Rails.application.routes.draw do
  # The Devise scope. `RbsInfer::Extensions::Devise::Generator` reads THIS line — it is the
  # only statically readable trace of `current_account` / `authenticate_account!`, which
  # Devise class_evals at boot.
  devise_for :accounts

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "posts#index"

  get "dashboard" => "dashboard#show"

  resources :posts do
    resources :comments, only: %i[create destroy]
    resources :assignments, only: %i[create], module: :posts
  end

  resources :users, only: %i[index show] do
    resource :avatar, only: %i[edit update], module: :users
    get :featured_post, on: :member
  end
end
