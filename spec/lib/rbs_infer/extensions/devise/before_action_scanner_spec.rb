# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/devise/before_action_scanner"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Devise::BeforeActionScanner do
  # Bare `"file.rb" => source` pairs land in **controllers (string keys
  # are fine through a double splat); `scopes:` stays a regular kwarg.
  def scan(scopes: ["user"], **controllers)
    Dir.mktmpdir do |dir|
      controllers.each do |path, source|
        full = File.join(dir, "app/controllers", path.to_s)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, source)
      end

      described_class.new(app_dir: dir, scopes: scopes).guarded_controllers
    end
  end

  it "guards a controller's own public actions" do
    guarded = scan(
      "posts_controller.rb" => <<~RUBY
        class PostsController < ApplicationController
          before_action :authenticate_user!

          def index; end
          def show; end

          private

          def set_post; end
        end
      RUBY
    )

    expect(guarded).to eq([{ class_name: "PostsController", scope: "user", actions: %w[index show] }])
  end

  it "inherits the guard from an app ancestor (ApplicationController)" do
    guarded = scan(
      "application_controller.rb" => <<~RUBY,
        class ApplicationController < ActionController::Base
          before_action :authenticate_user!
        end
      RUBY
      "posts_controller.rb" => <<~RUBY
        class PostsController < ApplicationController
          def index; end
        end
      RUBY
    )

    expect(guarded).to contain_exactly(
      { class_name: "PostsController", scope: "user", actions: ["index"] }
    )
  end

  it "honors only:/except: on the guard" do
    guarded = scan(
      "a_controller.rb" => <<~RUBY,
        class AController < ApplicationController
          before_action :authenticate_user!, only: [:show]

          def index; end
          def show; end
        end
      RUBY
      "b_controller.rb" => <<~RUBY
        class BController < ApplicationController
          before_action :authenticate_user!, except: [:index]

          def index; end
          def show; end
        end
      RUBY
    )

    expect(guarded).to contain_exactly(
      { class_name: "AController", scope: "user", actions: ["show"] },
      { class_name: "BController", scope: "user", actions: ["show"] }
    )
  end

  it "drops actions skipped via skip_before_action" do
    guarded = scan(
      "application_controller.rb" => <<~RUBY,
        class ApplicationController < ActionController::Base
          before_action :authenticate_user!
        end
      RUBY
      "public_controller.rb" => <<~RUBY,
        class PublicController < ApplicationController
          skip_before_action :authenticate_user!

          def landing; end
        end
      RUBY
      "mixed_controller.rb" => <<~RUBY
        class MixedController < ApplicationController
          skip_before_action :authenticate_user!, only: [:landing]

          def landing; end
          def dashboard; end
        end
      RUBY
    )

    expect(guarded).to contain_exactly(
      { class_name: "MixedController", scope: "user", actions: ["dashboard"] }
    )
  end

  it "skips controllers whose superclass chain leaves the app" do
    guarded = scan(
      "application_controller.rb" => <<~RUBY,
        class ApplicationController < ActionController::Base
          before_action :authenticate_user!
        end
      RUBY
      "users/registrations_controller.rb" => <<~RUBY
        class Users::RegistrationsController < Devise::RegistrationsController
          def create; end
        end
      RUBY
    )

    expect(guarded).to be_empty
  end

  describe "#guarded_handlers" do
    def scan_handlers(scopes: ["user"], **controllers)
      Dir.mktmpdir do |dir|
        controllers.each do |path, source|
          full = File.join(dir, "app/controllers", path.to_s)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, source)
        end

        described_class.new(app_dir: dir, scopes: scopes).guarded_handlers
      end
    end

    it "narrows handlers declared after the guard, attributed to the defining class" do
      handlers = scan_handlers(
        "application_controller.rb" => <<~RUBY
          class ApplicationController < ActionController::Base
            before_action :authenticate_user!
            before_action :set_authenticated_user

            private

            def set_authenticated_user
              Current.user = current_user
            end
          end
        RUBY
      )

      expect(handlers).to eq([
        { class_name: "ApplicationController", scope: "user", handlers: ["set_authenticated_user"] },
      ])
    end

    it "does not narrow handlers declared before the guard" do
      handlers = scan_handlers(
        "application_controller.rb" => <<~RUBY
          class ApplicationController < ActionController::Base
            before_action :set_locale
            before_action :authenticate_user!

            private

            def set_locale; end
          end
        RUBY
      )

      expect(handlers).to be_empty
    end

    it "requires an unconditional guard" do
      handlers = scan_handlers(
        "application_controller.rb" => <<~RUBY
          class ApplicationController < ActionController::Base
            before_action :authenticate_user!, only: [:show]
            before_action :set_authenticated_user

            private

            def set_authenticated_user; end
          end
        RUBY
      )

      expect(handlers).to be_empty
    end

    it "narrows a subclass handler under an inherited guard" do
      handlers = scan_handlers(
        "application_controller.rb" => <<~RUBY,
          class ApplicationController < ActionController::Base
            before_action :authenticate_user!
          end
        RUBY
        "posts_controller.rb" => <<~RUBY
          class PostsController < ApplicationController
            before_action :set_post

            private

            def set_post; end
          end
        RUBY
      )

      expect(handlers).to eq([
        { class_name: "PostsController", scope: "user", handlers: ["set_post"] },
      ])
    end

    it "drops all handler narrowing when any controller skips the guard" do
      handlers = scan_handlers(
        "application_controller.rb" => <<~RUBY,
          class ApplicationController < ActionController::Base
            before_action :authenticate_user!
            before_action :set_authenticated_user

            private

            def set_authenticated_user; end
          end
        RUBY
        "public_controller.rb" => <<~RUBY
          class PublicController < ApplicationController
            skip_before_action :authenticate_user!

            def landing; end
          end
        RUBY
      )

      expect(handlers).to be_empty
    end
  end

  it "matches guards per scope" do
    guarded = scan(
      scopes: %w[user admin],
      "admin_controller.rb" => <<~RUBY
        class AdminController < ApplicationController
          before_action :authenticate_admin!

          def index; end
        end
      RUBY
    )

    expect(guarded).to eq([{ class_name: "AdminController", scope: "admin", actions: ["index"] }])
  end
end
