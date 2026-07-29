require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/active_record/runtime_generator"
require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator do
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

  def source_of(result, filename)
    result.find { |f| f.filename == filename }&.source
  end

  ASSIGNMENT = <<~RUBY
    class Assignment < ApplicationRecord
      belongs_to :post
      belongs_to :owner, class_name: "User"

      before_validation :log_post_user_name

      def log_post_user_name
        post.user.name
      end
    end
  RUBY

  POST = <<~RUBY
    class Post < ApplicationRecord
      has_many :assignments, dependent: :destroy
    end
  RUBY

  describe "model reopen (save flow)" do
    it "runs the before_validation callbacks from save" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")

        expect(model).to include("class Assignment\n")
        expect(model).to match(/def save\(\*\*\)\n\s*run_before_validation_callbacks\n\s*true\n\s*end/)
        expect(model).to match(/def run_before_validation_callbacks\n\s*log_post_user_name\n\s*end/)
        expect(Prism.parse(model).success?).to be(true)
      end
    end

    it "calls every before_validation callback, in order" do
      model_src = <<~RUBY
        class Assignment < ApplicationRecord
          belongs_to :post
          before_validation :a, :b
          before_validation :c, if: :ready?
        end
      RUBY
      in_app("app/models/assignment.rb" => model_src) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")
        expect(model).to match(/def run_before_validation_callbacks\n\s*a\n\s*b\n\s*c\n\s*end/)
      end
    end

    it "reopens a belongs_to `default:` lambda as a before_validation callback" do
      # `belongs_to :owner, default: -> { post.user }` runs its lambda in a
      # before_validation callback (`self.owner ||= post.user`), so the deref of
      # a nilable belongs_to inside it (`post.user`) becomes reachable from save
      # and the contract machinery can narrow it — same flow as a named callback.
      model_src = <<~RUBY
        class Assignment < ApplicationRecord
          belongs_to :post
          belongs_to :owner, class_name: "User", default: -> { post.user }
        end
      RUBY
      in_app("app/models/assignment.rb" => model_src, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")

        expect(model).to match(/def run_before_validation_callbacks\n\s*run_belongs_to_default_callbacks\n\s*end/)
        expect(model).to match(/def run_belongs_to_default_callbacks\n\s*run_belongs_to_default_owner\n\s*end/)
        expect(model).to match(/def run_belongs_to_default_owner\n\s*self\.owner \|\|= post\.user\n\s*end/)
        expect(Prism.parse(model).success?).to be(true)
      end
    end

    it "does not reopen a belongs_to without a `default:`" do
      # A plain belongs_to has no default lambda to run, so no callback is emitted
      # for it (only `belongs_to :owner, default:` would produce one).
      plain = "class Assignment < ApplicationRecord\n  belongs_to :post\nend\n"
      in_app("app/models/assignment.rb" => plain, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")
        # No save flow at all: no before_validation callback and no default lambda.
        expect(model).to be_nil
      end
    end

    it "emits nothing when a has_many's element is not a scanned model" do
      # POST has `has_many :assignments` but Assignment isn't provided here, so
      # its class/proxy can't be modeled — the association is skipped, and with
      # no before_validation callback either, nothing is emitted.
      in_app("app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build).to be_empty
      end
    end
  end

  describe "owner reopen (association getter)" do
    it "returns the owner-specific proxy from the has_many getter, passing self" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "post.rb")

        expect(owner).to include("class Post\n")
        # 2 args (klass, self) to match the real CollectionProxy constructor;
        # `self` is captured as the owner.
        expect(owner).to match(/def assignments\n\s*Post_Assignment::ActiveRecord_Associations_CollectionProxy\.new\(Assignment, self\)\n\s*end/)
        expect(Prism.parse(owner).success?).to be(true)
      end
    end
  end

    # felixefelip/rbs_infer#128. `has_many :recomendacao_vacinas` inside `Caderneta`
    # resolves to `Caderneta::RecomendacaoVacina` when that exists — Ruby looks a constant
    # up from the enclosing namespace outward, and `compute_type` follows suit. Matching on
    # the bare `classify` (`RecomendacaoVacina`) found no scanned model under that name and
    # dropped the association entirely: no getter, no proxy reopen, and
    # `caderneta.recomendacao_vacinas` had no type at all.
    it "resolves a namespaced element from the owner's namespace outward" do
      in_app(
        "app/models/caderneta.rb" => <<~RUBY,
          class Caderneta < ApplicationRecord
            has_many :recomendacao_vacinas, dependent: :destroy, inverse_of: :caderneta
          end
        RUBY
        "app/models/caderneta/recomendacao_vacina.rb" => <<~RUBY
          class Caderneta::RecomendacaoVacina < ApplicationRecord
            belongs_to :caderneta
          end
        RUBY
      ) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "caderneta.rb")

        expect(owner).to match(
          /def recomendacao_vacinas\n\s*Caderneta_Caderneta_RecomendacaoVacina::ActiveRecord_Associations_CollectionProxy\.new\(Caderneta::RecomendacaoVacina, self\)/
        )
      end
    end

    # The outward walk must not shadow a top-level element with a same-named nested one
    # that does not exist — `has_many :posts` in `Caderneta` is still `::Post`.
    it "falls through to the top-level element when the owner has no nested one" do
      in_app(
        "app/models/caderneta.rb" => "class Caderneta < ApplicationRecord\n  has_many :posts\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\n  belongs_to :caderneta\nend\n"
      ) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "caderneta.rb")

        expect(owner).to match(/Caderneta_Post::ActiveRecord_Associations_CollectionProxy\.new\(Post, self\)/)
      end
    end

  # felixefelip/rbs_infer#139. An association is as often declared in a concern's
  # `included do` as in the model's own body (`has_many :notifications` inside
  # `User::Notifiable`). rbs_rails sees it — it reflects at runtime, where the
  # concern is already included — but this generator reads SOURCE, and reading
  # `user.rb` alone saw no `has_many` at all: no getter, no proxy reopen, and
  # `user.notifications` with no type.
  describe "associations from a concern" do
    NOTIFIABLE = <<~RUBY
      module User::Notifiable
        extend ActiveSupport::Concern

        included do
          has_many :notifications, dependent: :destroy
        end
      end
    RUBY

    USER = <<~RUBY
      class User < ApplicationRecord
        include User::Notifiable
      end
    RUBY

    NOTIFICATION = <<~RUBY
      class Notification < ApplicationRecord
        belongs_to :user
      end
    RUBY

    def concern_app(extra = {})
      in_app({
        "app/models/user.rb" => USER,
        "app/models/user/notifiable.rb" => NOTIFIABLE,
        "app/models/notification.rb" => NOTIFICATION
      }.merge(extra)) { |dir| yield described_class.new(app_dir: dir).build }
    end

    it "emits the getter on the includer, not on the concern" do
      concern_app do |files|
        expect(source_of(files, "user.rb")).to match(
          /class User\n.*def notifications\n\s*User_Notification::ActiveRecord_Associations_CollectionProxy\.new\(Notification, self\)\n\s*end/m
        )
        # The concern is not a model — it owns no association of its own.
        expect(files.map(&:filename)).not_to include("user_notifiable.rb")
      end
    end

    it "emits the proxy reopen with the construction flow" do
      concern_app do |files|
        proxy = source_of(files, "user_notification.rb")
        expect(proxy).to include("class User_Notification::ActiveRecord_Associations_CollectionProxy\n")
        expect(proxy).to match(/def build\(\*\)\n\s*record = Notification\.new\n\s*record\.user = owner\n\s*record\n\s*end/)
      end
    end

    it "resolves a concern written by its bare name from the host's namespace" do
      # `include Notifiable` inside `class User` is `User::Notifiable` — Ruby
      # searches the lexical scope outward, and a concern is conventionally
      # nested under its host.
      concern_app("app/models/user.rb" => "class User < ApplicationRecord\n  include Notifiable\nend\n") do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end

    it "honours class_name: on a concern's has_many" do
      bundled = <<~RUBY
        module User::Notifiable
          extend ActiveSupport::Concern

          included do
            has_many :notification_bundles, class_name: "Notification::Bundle", dependent: :destroy
          end
        end
      RUBY
      concern_app(
        "app/models/user/notifiable.rb" => bundled,
        "app/models/notification/bundle.rb" => "class Notification::Bundle < ApplicationRecord\n  belongs_to :user\nend\n"
      ) do |files|
        expect(source_of(files, "user.rb")).to match(
          /def notification_bundles\n\s*User_Notification_Bundle::ActiveRecord_Associations_CollectionProxy\.new\(Notification::Bundle, self\)/
        )
      end
    end

    it "splices a concern's before_validation callbacks at the include site" do
      # Rails registers a concern's callbacks when the `include` runs, so they
      # sit between the class's own declarations — the order the pseudo-code
      # must reproduce, since `run_before_validation_callbacks` calls them in
      # sequence.
      concern = <<~RUBY
        module Notification::Stampable
          extend ActiveSupport::Concern

          included do
            before_validation :stamp
          end
        end
      RUBY
      model = <<~RUBY
        class Notification < ApplicationRecord
          before_validation :first
          include Notification::Stampable
          before_validation :last
        end
      RUBY
      concern_app(
        "app/models/notification.rb" => model,
        "app/models/notification/stampable.rb" => concern
      ) do |files|
        expect(source_of(files, "notification.rb")).to match(
          /def run_before_validation_callbacks\n\s*first\n\s*stamp\n\s*last\n\s*end/
        )
      end
    end

    it "keeps a single getter when the concern and the class declare the same association" do
      # A redeclaration replaces the reflection at runtime; emitting both would
      # define `notifications` twice in the reopen, which collides in the
      # inferred RBS.
      both = "class User < ApplicationRecord\n  include User::Notifiable\n  has_many :notifications, dependent: :destroy\nend\n"
      concern_app("app/models/user.rb" => both) do |files|
        expect(source_of(files, "user.rb").scan(/def notifications\n/).size).to eq(1)
      end
    end

    it "follows a concern that includes another concern" do
      outer = <<~RUBY
        module User::Notifiable
          extend ActiveSupport::Concern
          include User::Bundling
        end
      RUBY
      inner = <<~RUBY
        module User::Bundling
          extend ActiveSupport::Concern

          included do
            has_many :notifications, dependent: :destroy
          end
        end
      RUBY
      concern_app(
        "app/models/user/notifiable.rb" => outer,
        "app/models/user/bundling.rb" => inner
      ) do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end

    it "ignores an include naming something outside the scanned models" do
      # A gem's concern has no source here to read; contributing nothing beats
      # inventing an association.
      concern_app("app/models/user.rb" => "class User < ApplicationRecord\n  include Devise::Models::Trackable\nend\n") do |files|
        expect(files.map(&:filename)).not_to include("user.rb")
      end
    end

    it "does not loop on mutually including concerns" do
      a = "module User::A\n  extend ActiveSupport::Concern\n  include User::B\nend\n"
      b = "module User::B\n  extend ActiveSupport::Concern\n  include User::A\n  included do\n    has_many :notifications\n  end\nend\n"
      concern_app(
        "app/models/user.rb" => "class User < ApplicationRecord\n  include User::A\nend\n",
        "app/models/user/a.rb" => a,
        "app/models/user/b.rb" => b
      ) do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end
  end

  describe "proxy reopen (construction flow)" do
    it "captures the owner and reopens with build/new/create/create!" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_assignment.rb")

        expect(proxy).to include("class Post_Assignment::ActiveRecord_Associations_CollectionProxy\n")
        # initialize(klass, owner) matches the real constructor arity; owner captured.
        expect(proxy).to match(/def initialize\(klass, owner\)\n\s*@owner = owner\n\s*end/)
        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        # build establishes the inverse belongs_to (`post`) from the owner.
        expect(proxy).to match(/def build\(\*\)\n\s*record = Assignment\.new\n\s*record\.post = owner\n\s*record\n\s*end/)
        # create = build (no args, matches the optional overload) + save.
        expect(proxy).to match(/def create\(\*\)\n\s*record = build\n\s*record\.save\n\s*record\n\s*end/)
        # create! delegates to `create` (single `save` call site) rather than
        # repeating build/save — keeps the caller chain linear so a precondition
        # on `save` can enforce (felixefelip/steep#65).
        expect(proxy).to match(/def create!\(\*\)\n\s*create or raise ActiveRecord::RecordInvalid\n\s*end/)
        expect(Prism.parse(proxy).success?).to be(true)
      end
    end

    it "names the proxy <Owner>_<Element> to match rbs_rails" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build.map(&:filename)).to include("post_assignment.rb")
      end
    end

    it "sets the inverse belongs_to whose target is the owner" do
      # Assignment belongs_to :post AND :owner(User); the has_many owner is Post,
      # so the inverse the proxy sets is `post`, not `owner`.
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_assignment.rb")
        expect(proxy).to include("record.post = owner")
        expect(proxy).not_to include("record.owner = owner")
      end
    end

    it "emits the proxy for a plain has_many (no before_validation needed)" do
      # rbs_infer owns the getter/proxy for every has_many now, so a plain
      # element (no before_validation) still gets a proxy — with the
      # construction flow, since it has an inverse belongs_to (`post`).
      plain = "class Assignment < ApplicationRecord\n  belongs_to :post\nend\n"
      in_app("app/models/assignment.rb" => plain, "app/models/post.rb" => POST) do |dir|
        files = described_class.new(app_dir: dir).build
        proxy = source_of(files, "post_assignment.rb")
        expect(proxy).not_to be_nil
        expect(proxy).to match(/def build\(\*\)\n\s*record = Assignment\.new\n\s*record\.post = owner\n\s*record\n\s*end/)
        # No save flow for the model — it has no before_validation callback.
        expect(files.map(&:filename)).not_to include("assignment.rb")
        # The owner still gets the getter.
        expect(source_of(files, "post.rb")).to match(/def assignments\n/)
      end
    end

    it "emits an owner-capture-only proxy for a has_many :through (no inverse belongs_to)" do
      # `Post has_many :tags, through: :post_tags` — Tag has no `belongs_to
      # :post`, so there's no inverse to establish: only `initialize`/`owner`.
      post = "class Post < ApplicationRecord\n  has_many :tags, through: :post_tags\nend\n"
      tag  = "class Tag < ApplicationRecord\n  has_many :posts, through: :post_tags\nend\n"
      in_app("app/models/post.rb" => post, "app/models/tag.rb" => tag) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_tag.rb")
        expect(proxy).not_to be_nil
        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        expect(proxy).not_to include("def build")
        expect(proxy).not_to include("record.save")
      end
    end
  end

  describe "RBS for invented methods" do
    it "does not hand-write a <Model>.rbs for run_before_validation_callbacks" do
      # The synthetic method is defined in the emitted `.rb`; rbs_infer infers
      # its RBS from that pseudo-code, so no `.rbs` is emitted here (a
      # hand-written one would collide with the inferred declaration).
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        files = described_class.new(app_dir: dir).build
        expect(files.map(&:filename)).not_to include("assignment.rbs")
        expect(files.map(&:filename)).to all(end_with(".rb"))
      end
    end
  end

  # Snapshot of the generated sidecar against the real dummy app, so a change in
  # the emitted pseudo-code shows up as a reviewable diff.
  #   Regenerate with: UPDATE_EXPECTATIONS=1 bundle exec rspec <this file>
  describe "dummy snapshot" do
    let(:expectations) { Pathname(DUMMY_APP_ROOT).dirname.join("expectations/steep_ar_runtime") }

    it "matches the expected files for every generated class" do
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

  describe "#generate (disk)" do
    it "writes one file per reopened class and removes a stale dir" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(stale)
        File.write(File.join(stale, "Old.rb"), "old")

        out = described_class.new(app_dir: dir).generate
        expect(Dir.children(out).sort).to eq(["assignment.rb", "post.rb", "post_assignment.rb"])
      end
    end

    it "removes the sidecar when nothing qualifies" do
      in_app("app/models/post.rb" => POST) do |dir|
        out = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(out)
        File.write(File.join(out, "Stale.rb"), "stale")

        described_class.new(app_dir: dir).generate
        expect(File.exist?(out)).to be(false)
      end
    end
  end
end
