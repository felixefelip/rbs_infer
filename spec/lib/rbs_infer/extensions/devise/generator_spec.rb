# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/devise/generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Devise::Generator do
  def generate(routes_source)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), routes_source)

      output_dir = File.join(dir, described_class::SIDECAR_DIR)
      scopes = described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      path = File.join(output_dir, described_class::FILENAME)
      [scopes, File.exist?(path) ? File.read(path) : nil]
    end
  end

  it "generates the four helpers for a basic devise_for" do
    scopes, source = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users
        root "home#index"
      end
    RUBY

    expect(scopes).to eq([{ scope: "user", class_name: "User" }])
    expect(source).to include("def current_user")
    expect(source).to include("def authenticate_user!")
    expect(source).to include("def user_signed_in?")
    expect(source).to include("def user_session")
  end

  it "emits parseable Ruby" do
    _, source = generate("Rails.application.routes.draw { devise_for :users }")

    expect(Prism.parse(source)).to be_success
  end

  # The point of the pseudo-code rewrite: the generator states no type at all. Everything
  # the old `.rbs` spelled out — the resource type, its `Validated` decoration, the
  # non-nil narrowing under the guard — is now inferred from these bodies.
  it "states no type anywhere" do
    _, source = generate("Rails.application.routes.draw { devise_for :users }")

    expect(source).not_to include("::Validated")
    expect(source).not_to include("->")
    expect(source.lines.grep(/@type/)).to eq(["  # @type instance: ActionController::Base\n"])
  end

  it "reads the resource through a finder, which is what types it" do
    _, source = generate("Rails.application.routes.draw { devise_for :users }")

    expect(source).to include(%(User.find_by(id: session["warden.user.user.key"])))
  end

  # The halt on the nil branch is the whole mechanism: the postconditions inferrer reads
  # it as "past this, `current_user` is non-nil", and the controller-runtime pseudo-code's
  # `return if performed?` after the callback promotes that to unconditional.
  it "halts on the unauthenticated branch" do
    _, source = generate("Rails.application.routes.draw { devise_for :users }")

    expect(source).to include(<<~RUBY.rstrip)
      def authenticate_user!
          unless current_user
            redirect_to("/")
            return
          end
    RUBY
  end

  # Devise's own host. Naming ApplicationController would both be less faithful and drag
  # the app's base controller into a generated file.
  it "includes the module into ActionController::Base, not ApplicationController" do
    _, source = generate("Rails.application.routes.draw { devise_for :users }")

    expect(source).to include("module ActionController\n  class Base\n    include DeviseScopedHelpers\n  end\nend")
    expect(source).not_to include("ApplicationController")
  end

  it "honors class_name:" do
    scopes, source = generate(<<~RUBY)
      Rails.application.routes.draw do
        devise_for :users, class_name: "Account", controllers: { registrations: "users/registrations" }
      end
    RUBY

    expect(scopes).to eq([{ scope: "user", class_name: "Account" }])
    expect(source).to include("Account.find_by(")
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
    scopes, source = generate(<<~RUBY)
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
    expect(source).to include("def current_admin")
    expect(source).to include("def current_member")
    expect(source.scan(/^module DeviseScopedHelpers$/).size).to eq(1)
  end

  it "classifies namespaced resources" do
    scopes, = generate('Rails.application.routes.draw { devise_for :admin_users }')

    expect(scopes).to eq([{ scope: "admin_user", class_name: "AdminUser" }])
  end

  it "writes nothing when routes have no devise_for" do
    scopes, source = generate(<<~RUBY)
      Rails.application.routes.draw do
        root "home#index"
      end
    RUBY

    expect(scopes).to eq([])
    expect(source).to be_nil
  end

  it "writes nothing when routes.rb is absent" do
    Dir.mktmpdir do |dir|
      generator = described_class.new(app_dir: dir, output_dir: File.join(dir, "sig"))

      expect(generator.generate_all).to eq([])
    end
  end

  # Losing the `devise_for` should leave no stale pseudo-code behind claiming helpers the
  # app no longer has.
  it "removes a stale sidecar dir when the app stops using devise" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      routes = File.join(dir, "config/routes.rb")
      output_dir = File.join(dir, described_class::SIDECAR_DIR)

      File.write(routes, "devise_for :users")
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all
      expect(File.exist?(File.join(output_dir, described_class::FILENAME))).to be(true)

      File.write(routes, 'root "home#index"')
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all
      expect(Dir.exist?(output_dir)).to be(false)
    end
  end

  # The `.steep_callbacks.yml` marker sidecar is gone: the guard's own body now proves the
  # resource present, so nothing has to pre-derive which controllers are narrowed.
  it "emits no callbacks sidecar for guarded controllers" do
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

      output_dir = File.join(dir, described_class::SIDECAR_DIR)
      described_class.new(app_dir: dir, output_dir: output_dir).generate_all

      expect(Dir.glob(File.join(output_dir, "**/*"), File::FNM_DOTMATCH).map { |p| File.basename(p) })
        .not_to include(".steep_callbacks.yml")
      expect(Dir.glob(File.join(output_dir, "*.rbs"))).to be_empty
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
