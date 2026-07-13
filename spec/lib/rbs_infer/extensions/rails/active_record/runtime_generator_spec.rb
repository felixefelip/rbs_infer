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
        expectations.rmtree if expectations.exist?
        expectations.mkpath
        files.each { |f| expectations.join(f.filename).write(f.source) }
      end

      aggregate_failures do
        files.each { |f| expect(f.source).to eq(expectations.join(f.filename).read) }
        # no stale/extra expectation files
        expect(expectations.children.map { |p| p.basename.to_s }.sort).to eq(files.map(&:filename).sort)
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
