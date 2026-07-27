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

      expect(source).to include("def redirect_to(*args)", "@__rbs_infer__performed = true")
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

  describe "the render override" do
    # The stripped lines of the per-controller `render` override, or nil when
    # the controller has none.
    def render_override(result, filename)
      source = source_of(result, filename) or return nil
      body = source[/^  def render\(.*?\)\n(.*?)^  end$/m, 1] or return nil

      body.lines.map(&:strip).reject(&:empty?)
    end

    # An action that renders a non-convention view (`create` failing to
    # `render :new`) is modelled as a `render` that marks the shared halt marker
    # and dispatches the view symbol to that view's compiled body, so the
    # render's call-site facts reach the rendered view.
    it "marks the halt and dispatches an explicit `render :view` to the view's body" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "<%= @post %>"
      )

      expect(render_override(result, "posts_controller.rb")).to eq(
        [
          "@__rbs_infer__performed = true",
          "case target",
          "when :new then ERBPostsNew.new(post: @post).__rbs_infer__body",
          "end",
          "true",
        ]
      )
    end

    # The constructor carries the ivars the VIEW'S TEMPLATE reads, which are the
    # keywords the view-runtime pseudo-code declares on `initialize`. Passing them
    # is what gives those parameters a type: the analyzer reads this call site, so
    # the controller's `@post` flows into the view and on into its partials
    # (felixefelip/rbs_infer#109). Without arguments they all infer `untyped`.
    it "passes the ivars the rendered template reads, sorted" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "<%= @post.title %> <%= @author %>"
      )

      expect(render_override(result, "posts_controller.rb"))
        .to include("when :new then ERBPostsNew.new(author: @author, post: @post).__rbs_infer__body")
    end

    it "emits a bare constructor for a template that reads no ivars" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "<h1>static</h1>"
      )

      expect(render_override(result, "posts_controller.rb"))
        .to include("when :new then ERBPostsNew.new.__rbs_infer__body")
    end

    # The view target is a NAMED optional parameter and the dispatch cases on it, rather
    # than `def render(*args)` + `case args.first`. Both type-check the same; only this
    # shape is legible to the fork's argument-sensitive entry facts, which key a partition
    # on a named positional parameter and correlate only a `case` whose subject is a plain
    # read of it. With it, `render :edit` from an action that ran `set_post` carries `@post`
    # into the `:edit` branch.
    it "takes the view target as a named optional parameter and cases on it" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      source = source_of(result, "posts_controller.rb")
      expect(source).to include("def render(target = nil, *rest)")
      expect(source).to include("case target")
      expect(source).not_to include("case args.first")
    end

    # The parameter stays OPTIONAL: a required one would make a bare `render` — or the
    # very common `render json: {}`, whose kwargs never fill a positional in Ruby 3 — an
    # arity error in the USER's controller, a false positive on their code.
    it "keeps the target optional so a bare render stays valid arity" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      expect(source_of(result, "posts_controller.rb")).to include("def render(target = nil,")
    end

    # The override marks the SAME halt marker the framework `render` sets, so
    # `performed?` reads it back regardless of which render ran.
    it "marks the same halt marker as the framework render" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      framework = source_of(result, "action_controller_base.rb")
      override = render_override(result, "posts_controller.rb")

      expect(override).to include("@__rbs_infer__performed = true")
      expect(framework).to include("@__rbs_infer__performed = true")
    end

    # The whole reason for reusing the real render call site: `render :new`
    # sits in the `else` of `if @post.save`, where `@post` is the failed
    # (non-`Validated`) record — the fact we want to carry into the view.
    it "finds a `render :view` nested inside a branch" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              if @post.save
                redirect_to @post
              else
                render :new
              end
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      expect(render_override(result, "posts_controller.rb")).to include(
        "when :new then ERBPostsNew.new.__rbs_infer__body"
      )
    end

    it "is public — declared before `private`" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      source = source_of(result, "posts_controller.rb")
      expect(source.index("def render(target = nil, *rest)")).to be < source.index("private")
    end

    it "de-duplicates and sorts the view symbols" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end

            def duplicate
              render :new
            end

            def update
              render :edit
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x",
        "app/views/posts/edit.html.erb" => "x"
      )

      whens = render_override(result, "posts_controller.rb").grep(/\Awhen/)
      expect(whens).to eq(
        [
          "when :edit then ERBPostsEdit.new.__rbs_infer__body",
          "when :new then ERBPostsNew.new.__rbs_infer__body",
        ]
      )
    end

    it "emits a `when` only for a view whose template exists" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end

            def update
              render :edit
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      override = render_override(result, "posts_controller.rb")
      expect(override).to include("when :new then ERBPostsNew.new.__rbs_infer__body")
      expect(override.join("\n")).not_to include(":edit")
    end

    it "omits the override when nothing is explicitly rendered" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def show; end
        end
      RUBY

      expect(render_override(result, "posts_controller.rb")).to be_nil
    end

    it "omits the override when the rendered view has no template" do
      result = build("app/controllers/posts_controller.rb" => <<~RUBY)
        class PostsController < ActionController::Base
          def create
            render :new
          end
        end
      RUBY

      expect(render_override(result, "posts_controller.rb")).to be_nil
    end

    # Cross-controller render: `UsersController` renders another controller's
    # view by absolute path. The dispatch stays on THIS controller (scoped
    # meet), keyed by the string exactly as written, resolved by absolute path.
    it "dispatches a foreign `render \"posts/new\"` by absolute path" do
      result = build(
        "app/controllers/users_controller.rb" => <<~RUBY,
          class UsersController < ActionController::Base
            def create
              render "posts/new"
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      expect(render_override(result, "users_controller.rb")).to include(
        'when "posts/new" then ERBPostsNew.new.__rbs_infer__body'
      )
    end

    it "treats a bare-string `render \"new\"` as controller-relative" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render "new"
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      expect(render_override(result, "posts_controller.rb")).to include(
        'when "new" then ERBPostsNew.new.__rbs_infer__body'
      )
    end

    it "omits a foreign render whose template does not exist" do
      result = build("app/controllers/users_controller.rb" => <<~RUBY)
        class UsersController < ActionController::Base
          def create
            render "posts/nope"
          end
        end
      RUBY

      expect(render_override(result, "users_controller.rb")).to be_nil
    end

    it "resolves a namespaced controller's view class" do
      result = build(
        "app/controllers/users/avatars_controller.rb" => <<~RUBY,
          class Users::AvatarsController < ActionController::Base
            def update
              render :edit
            end
          end
        RUBY
        "app/views/users/avatars/edit.html.erb" => "x"
      )

      expect(render_override(result, "users_avatars_controller.rb")).to include(
        "when :edit then ERBUsersAvatarsEdit.new.__rbs_infer__body"
      )
    end

    # Every view of the controller gets a branch, not only the ones an explicit
    # `render :view` names: the implicit convention render is emitted as
    # `render(:show)` too, so a `case` limited to explicit targets would leave
    # it dispatching nowhere and the view would lose the arguments that type it.
    it "covers every view of the controller, not only the explicitly rendered ones" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def show; end

            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/show.html.erb" => "<%= @post %>",
        "app/views/posts/new.html.erb" => "<%= @post %>",
        "app/views/posts/index.html.erb" => "<%= @posts %>"
      )

      expect(render_override(result, "posts_controller.rb").grep(/\Awhen/)).to eq(
        [
          "when :index then ERBPostsIndex.new(posts: @posts).__rbs_infer__body",
          "when :new then ERBPostsNew.new(post: @post).__rbs_infer__body",
          "when :show then ERBPostsShow.new(post: @post).__rbs_infer__body",
        ]
      )
    end

    # A partial is never an action's render target — the VIEW that renders it
    # constructs it, from the view-runtime pseudo-code's own `render`.
    it "skips partials when sweeping the view directory" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def show; end
          end
        RUBY
        "app/views/posts/show.html.erb" => "x",
        "app/views/posts/_form.html.erb" => "x"
      )

      whens = render_override(result, "posts_controller.rb").grep(/\Awhen/)
      expect(whens).to eq(["when :show then ERBPostsShow.new.__rbs_infer__body"])
    end

    # The directory sweep and the explicit targets both name `:new`; a second
    # branch for it would be dead code.
    it "emits one branch when an explicit render names a view the sweep found" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def create
              render :new
            end
          end
        RUBY
        "app/views/posts/new.html.erb" => "x"
      )

      whens = render_override(result, "posts_controller.rb").grep(/\Awhen/)
      expect(whens).to eq(["when :new then ERBPostsNew.new.__rbs_infer__body"])
    end

    # A controller that renders nothing explicitly still needs the override:
    # its actions' implicit renders go through it.
    it "emits the override for a controller with a view but no explicit render" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def show; end
          end
        RUBY
        "app/views/posts/show.html.erb" => "x"
      )

      expect(render_override(result, "posts_controller.rb")).to include(
        "when :show then ERBPostsShow.new.__rbs_infer__body"
      )
    end
  end

  # Rails ends an action with `render action_name`. Emitting that call — rather
  # than constructing the view inline — makes the implicit and explicit renders
  # of a view two call sites of ONE method, which is the shape the fork's
  # argument-sensitive entry facts read. Constructed inline they were two
  # separate constructor call sites whose facts never met.
  describe "the implicit convention render" do
    it "ends the runner with `render :action`, not a view constructor" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def show; end
          end
        RUBY
        "app/views/posts/show.html.erb" => "<%= @post %>"
      )

      source = source_of(result, "posts_controller.rb")

      expect(source).to include("    render :show\n  end")
      expect(source).not_to include("ERBPostsShow.new(post: @post).__rbs_infer__body\n  end")
    end

    it "emits no implicit render when the action has no convention template" do
      result = build(
        "app/controllers/posts_controller.rb" => <<~RUBY,
          class PostsController < ActionController::Base
            def destroy; end
          end
        RUBY
        "app/views/posts/show.html.erb" => "x"
      )

      body = source_of(result, "posts_controller.rb")[/def __rbs_infer__run_destroy\n(.*?)^  end$/m, 1]
      expect(body).not_to match(/^\s*render\b/)
    end
  end

  # Snapshot of the generated pseudo-code against the real dummy app, mirroring
  # the AR- and Current-runtime snapshots: a change in the emitted pseudo-code
  # shows up as a reviewable diff, and a failure points at the right layer
  # (reopen changed → generator bug; identical reopen with changed RBS →
  # inference-pipeline bug).
  #   Regenerate with: UPDATE_EXPECTATIONS=1 bundle exec rspec <this file>
  describe "dummy snapshot" do
    let(:expectations) { Pathname(DUMMY_APP_ROOT).dirname.join("expectations/steep_controller_runtime") }

    it "matches the expected pseudo-code for every controller" do
      files = described_class.new(app_dir: DUMMY_APP_ROOT).build

      if ENV["UPDATE_EXPECTATIONS"]
        # `.rb` only: the inferred `.rbs` snapshots share this directory
        # (spec/integration/rails_dummy_spec.rb) and rmtree would take them out.
        expectations.glob("**/*.rb").each(&:delete) if expectations.exist?
        expectations.mkpath
        files.each { |f| expectations.join(f.filename).write(f.source) }
      end

      aggregate_failures do
        files.each { |f| expect(f.source).to eq(expectations.join(f.filename).read) }
        # no stale/extra expectation files
        # `.rb` only: the inferred `.rbs` snapshots live in this same directory
        # (spec/integration/rails_dummy_spec.rb, "runtime pseudo-code RBS") and are
        # not this generator's output.
        pseudo_code = expectations.children.select { |p| p.extname == ".rb" }
        expect(pseudo_code.map { |p| p.basename.to_s }.sort).to eq(files.map(&:filename).sort)
      end
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
