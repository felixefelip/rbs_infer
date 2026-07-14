# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/controllers/runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator do
  def in_app(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end

  def build(files)
    in_app(files) { |dir| described_class.new(app_dir: dir).build }
  end

  def source_of(result, filename)
    result.find { |f| f.filename == filename }&.source
  end

  # The runner body of one action, stripped of indentation.
  def runner(result, filename, action)
    source = source_of(result, filename) or return nil
    body = source[/^  def __rbs_infer__run_#{action}\n(.*?)^  end$/m, 1] or return nil

    body.lines.map(&:strip).reject(&:empty?)
  end

  describe "the request flow of an action" do
    it "runs the before_action chain, then the action" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ApplicationController
          before_action :set_post

          def show
          end

          private

          def set_post
            @post = Post.find(params[:id])
          end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to eq(
        ["set_post", "return if performed?", "show"]
      )
    end

    it "honours only:/except:" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ApplicationController
          before_action :set_post, only: %i[show]
          before_action :audit, except: %i[show]

          def show; end
          def index; end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to include("set_post")
      expect(runner(result, "posts_controller.rb", "show")).not_to include("audit")
      expect(runner(result, "posts_controller.rb", "index")).to include("audit")
      expect(runner(result, "posts_controller.rb", "index")).not_to include("set_post")
    end

    it "runs ancestors' callbacks before the subclass's own" do
      result = build(
        "app/controllers/application_controller.rb" => <<~RUBY,
          class ApplicationController < ActionController::Base
            before_action :require_authentication
          end
        RUBY
        "app/controllers/posts_controller.rb" => <<~RUBY
          class PostsController < ApplicationController
            before_action :set_post

            def show; end
          end
        RUBY
      )

      expect(runner(result, "posts_controller.rb", "show")).to eq(
        [
          "require_authentication", "return if performed?",
          "set_post", "return if performed?",
          "show",
        ]
      )
    end

    it "hoists prepend_before_action to the front of the chain" do
      result = build(
        "app/controllers/application_controller.rb" => <<~RUBY,
          class ApplicationController < ActionController::Base
            before_action :require_authentication
          end
        RUBY
        "app/controllers/posts_controller.rb" => <<~RUBY
          class PostsController < ApplicationController
            prepend_before_action :set_tenant

            def show; end
          end
        RUBY
      )

      expect(runner(result, "posts_controller.rb", "show").first).to eq("set_tenant")
    end
  end

  describe "concerns" do
    # The Rails 8 layout: auth lives in a concern, and its callbacks are
    # registered by `included do` — invisible to a scanner that only reads
    # class bodies.
    it "splices a concern's `included do` callbacks at the include site" do
      result = build(
        "app/controllers/concerns/authentication.rb" => <<~RUBY,
          module Authentication
            extend ActiveSupport::Concern

            included do
              before_action :require_account
              before_action :require_authentication
            end
          end
        RUBY
        "app/controllers/posts_controller.rb" => <<~RUBY
          class PostsController < ActionController::Base
            include Authentication

            before_action :set_post

            def show; end
          end
        RUBY
      )

      expect(runner(result, "posts_controller.rb", "show")).to eq(
        [
          "require_account", "return if performed?",
          "require_authentication", "return if performed?",
          "set_post", "return if performed?",
          "show",
        ]
      )
    end

    it "drops a callback the controller skips" do
      result = build(
        "app/controllers/concerns/authentication.rb" => <<~RUBY,
          module Authentication
            extend ActiveSupport::Concern

            included do
              before_action :require_authentication
            end
          end
        RUBY
        "app/controllers/sessions_controller.rb" => <<~RUBY
          class SessionsController < ActionController::Base
            include Authentication

            skip_before_action :require_authentication, only: %i[new]

            def new; end
            def destroy; end
          end
        RUBY
      )

      expect(runner(result, "sessions_controller.rb", "new")).to eq(["new"])
      expect(runner(result, "sessions_controller.rb", "destroy")).to include("require_authentication")
    end
  end

  describe "conditional callbacks" do
    # The payoff of the pseudo-code approach: `if:` becomes a literal Ruby
    # condition and the checker resolves the predicate itself — no static
    # proof of the condition is attempted here.
    it "emits a symbol `if:`/`unless:` as a literal condition" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          before_action :ensure_can_access, if: :authenticated?
          before_action :audit, unless: :internal?

          def show; end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to include(
        "ensure_can_access if authenticated?", "audit if !internal?"
      )
    end

    # Rails instance_execs a lambda condition on the controller, so its body is
    # valid pseudo-code as written — splice it rather than giving up on it.
    it "inlines a zero-arity lambda condition" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          before_action :set_post, if: -> { params[:id].present? }

          def show; end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to include(
        "set_post if (params[:id].present?)"
      )
    end

    # A condition we cannot splice (a lambda taking the controller) is modelled
    # as "may or may not run" — it proves nothing, rather than inventing a fact.
    it "models an unnameable condition as an opaque predicate" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          before_action :set_post, if: ->(controller) { controller.stale? }

          def show; end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to include(
        "set_post if __rbs_infer__unknown_condition?"
      )
      # It needs a BODY: the analyzer emits the RBS, and it can only declare
      # what it can infer from one.
      expect(source_of(result, "action_controller_base.rb")).to include(
        "def __rbs_infer__unknown_condition?"
      )
    end

    it "inlines a `before_action do … end` block body" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          before_action do
            Current.request_id = request.uuid
          end

          def show; end
        end
      RUBY

      expect(runner(result, "posts_controller.rb", "show")).to eq(
        ["Current.request_id = request.uuid", "return if performed?", "show"]
      )
    end
  end

  describe "the framework reopen" do
    it "records the halt in redirect_to/render/head and reads it back with performed?" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def show; end
        end
      RUBY

      source = source_of(result, "action_controller_base.rb")

      expect(source).to include("def redirect_to(*args)", "@__rbs_infer__halted = true")
      # Rails halts the chain with `performed?` (its callback terminator calls
      # exactly that), so the pseudo-code drives the real predicate.
      expect(source).to include("def performed?")
    end

    # The RBS for these bodies comes from the analyzer (`rbs_infer sig/`), not
    # from here: emitting it in both places declares the same method twice, and
    # RBS rejects that.
    it "emits no .rbs of its own" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def show; end
        end
      RUBY

      expect(result.map(&:filename)).to all(end_with(".rb"))
    end

    it "defines the runner methods privately" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def show; end
        end
      RUBY

      expect(source_of(result, "posts_controller.rb")).to include(
        "private", "def __rbs_infer__run_show"
      )
    end
  end

  describe "what is not a controller" do
    # `app/controllers` also holds framework reopens and plain classes; only
    # a `*Controller` with actions has a request flow to model.
    it "ignores classes that are not controllers" do
      result = build(
        "app/controllers/support/formatter.rb" => <<~RUBY,
          module Support
            class Formatter
              def call; end
            end
          end
        RUBY
        "app/controllers/posts_controller.rb" => <<~RUBY
          class PostsController < ActionController::Base
            def show; end
          end
        RUBY
      )

      expect(result.map(&:filename)).not_to include("support_formatter.rb")
      expect(result.map(&:filename)).to include("posts_controller.rb")
    end

    it "ignores non-action public methods (predicates, setters, bangs)" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def show; end
          def stale?; end
          def title=(value); end
        end
      RUBY

      source = source_of(result, "posts_controller.rb")

      expect(source).to include("def __rbs_infer__run_show")
      expect(source).not_to include("stale?", "title=")
    end

    it "emits nothing for an app with no controllers" do
      expect(build("app/models/post.rb" => "class Post; end")).to be_empty
    end
  end

  describe "#generate" do
    it "writes the sidecar and removes a stale one" do
      in_app("app/controllers/posts_controller.rb" => "class PostsController < ActionController::Base\n  def show; end\nend\n") do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR, "gone_controller.rb")
        FileUtils.mkdir_p(File.dirname(stale))
        File.write(stale, "# stale")

        described_class.new(app_dir: dir).generate

        expect(File).to exist(File.join(dir, described_class::SIDECAR_DIR, "posts_controller.rb"))
        expect(File).not_to exist(stale)
      end
    end
  end
end
