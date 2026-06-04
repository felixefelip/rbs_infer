# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/devise/generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Devise::Generator do
  def generate(routes_source)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), routes_source)

      output_dir = File.join(dir, "sig/rbs_infer_devise")
      generator = described_class.new(app_dir: dir, output_dir: output_dir)
      scopes = generator.generate_all

      helpers_path = File.join(output_dir, "devise_scoped_helpers.rbs")
      controller_path = File.join(output_dir, "application_controller.rbs")
      rbs = [helpers_path, controller_path]
              .select { |p| File.exist?(p) }
              .map { |p| File.read(p) }
              .join("\n")
      [scopes, rbs.empty? ? nil : rbs]
    end
  end

  it "generates the four helpers for a basic devise_for" do
    scopes, rbs = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users
        root "home#index"
      end
    RUBY

    expect(scopes).to eq([{ scope: "user", class_name: "User" }])
    expect(rbs).to include("def current_user: () -> User?")
    expect(rbs).to include("def authenticate_user!: (?::Hash[::Symbol, untyped] opts) -> User")
    expect(rbs).to include("def user_signed_in?: () -> bool")
    expect(rbs).to include("def user_session: () -> untyped")
    expect(rbs).to include("class ApplicationController\n  include DeviseScopedHelpers\nend")
  end

  it "produces parseable RBS in both files" do
    _, rbs = generate("Rails.application.routes.draw { devise_for :users }")

    expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
  end

  it "emits the ApplicationController reopen in its own filename-matching file" do
    # MethodTypeResolver's RBS lookup matches sig files by class-name
    # path; the include is invisible if it lives under another filename.
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "devise_for :users")

      output_dir = File.join(dir, "sig/rbs_infer_devise")
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      controller_rbs = File.read(File.join(output_dir, "application_controller.rbs"))
      expect(controller_rbs).to include("class ApplicationController\n  include DeviseScopedHelpers\nend")
    end
  end

  it "honors class_name:" do
    scopes, rbs = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users, class_name: "Account", controllers: { registrations: "users/registrations" }
      end
    RUBY

    expect(scopes).to eq([{ scope: "user", class_name: "Account" }])
    expect(rbs).to include("def current_user: () -> Account?")
  end

  it "honors singular:" do
    scopes, = generate('Rails.application.routes.draw { devise_for :users, singular: :member }')

    expect(scopes).to eq([{ scope: "member", class_name: "User" }])
  end

  it "honors as: for the scoped path (mirroring Devise::Mapping)" do
    scopes, = generate('Rails.application.routes.draw { devise_for :users, as: :admins }')

    expect(scopes).to eq([{ scope: "admin", class_name: "User" }])
  end

  it "handles multiple scopes across calls and within one call" do
    scopes, rbs = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users, :admins
        devise_for :members
      end
    RUBY

    expect(scopes).to contain_exactly(
      { scope: "user", class_name: "User" },
      { scope: "admin", class_name: "Admin" },
      { scope: "member", class_name: "Member" }
    )
    expect(rbs).to include("def current_admin: () -> Admin?")
    expect(rbs).to include("def current_member: () -> Member?")
  end

  it "classifies namespaced resources" do
    scopes, = generate('Rails.application.routes.draw { devise_for :admin_users }')

    expect(scopes).to eq([{ scope: "admin_user", class_name: "AdminUser" }])
  end

  it "writes nothing when routes have no devise_for" do
    scopes, rbs = generate(<<~RUBY)
      Rails.application.routes.draw do
        root "home#index"
      end
    RUBY

    expect(scopes).to eq([])
    expect(rbs).to be_nil
  end

  it "writes nothing when routes.rb is absent" do
    Dir.mktmpdir do |dir|
      generator = described_class.new(app_dir: dir, output_dir: File.join(dir, "sig"))

      expect(generator.generate_all).to eq([])
    end
  end

  it "decorates the resource with the Validated marker when rbs_rails emitted it" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "devise_for :users")
      # Marker emitido pelo rbs_rails para models com validação incondicional
      FileUtils.mkdir_p(File.join(dir, "sig/rbs_rails/app/models"))
      File.write(File.join(dir, "sig/rbs_rails/app/models/user.rbs"), <<~RBS)
        class User < ApplicationRecord
        end

        class ::User::Validated
        end
      RBS

      output_dir = File.join(dir, "sig/rbs_infer_devise")
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      rbs = File.read(File.join(output_dir, "devise_scoped_helpers.rbs"))
      expect(rbs).to include("def current_user: () -> (User & User::Validated)?")
      expect(rbs).to include("def authenticate_user!: (?::Hash[::Symbol, untyped] opts) -> (User & User::Validated)")
      expect(rbs).to include("    def current_user: () -> (User & User::Validated)\n") # marker, não-nil
      expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
    end
  end

  it "falls back to the plain class when no Validated marker exists" do
    _, rbs = generate("Rails.application.routes.draw { devise_for :users }")

    expect(rbs).to include("def current_user: () -> User?")
    expect(rbs).not_to include("User::Validated")
  end

  it "emits the per-scope Authenticated marker inside the helpers module" do
    _, rbs = generate("Rails.application.routes.draw { devise_for :users }")

    expect(rbs).to include("module UserAuthenticated")
    expect(rbs).to include("    def current_user: () -> User")
    expect(rbs).to include("    def user_signed_in?: () -> true")
  end

  it "emits the callbacks sidecar for before_action-guarded controllers" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "devise_for :users")
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))
      File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RUBY)
        class PostsController < ApplicationController
          before_action :authenticate_user!

          def index; end
        end
      RUBY

      output_dir = File.join(dir, "sig/rbs_infer_devise")
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      sidecar = YAML.safe_load(File.read(File.join(output_dir, ".steep_callbacks.yml")))
      expect(sidecar["callbacks"]).to eq([
        {
          "class" => "PostsController",
          "applies_self" => "PostsController & DeviseScopedHelpers::UserAuthenticated",
          "runs_before" => ["index"],
        },
      ])
    end
  end

  it "omits the callbacks sidecar when no controller is guarded" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "devise_for :users")

      output_dir = File.join(dir, "sig/rbs_infer_devise")
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      expect(File.exist?(File.join(output_dir, ".steep_callbacks.yml"))).to be(false)
    end
  end

  it "dedupes repeated devise_for of the same resource" do
    scopes, = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users
        devise_for :users
      end
    RUBY

    expect(scopes).to eq([{ scope: "user", class_name: "User" }])
  end
end
