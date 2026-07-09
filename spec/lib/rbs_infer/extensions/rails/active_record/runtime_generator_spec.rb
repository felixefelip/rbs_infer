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
        model = source_of(described_class.new(app_dir: dir).build, "Assignment.rb")

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
        model = source_of(described_class.new(app_dir: dir).build, "Assignment.rb")
        expect(model).to match(/def run_before_validation_callbacks\n\s*a\n\s*b\n\s*c\n\s*end/)
      end
    end

    it "emits no file for a model without before_validation callbacks" do
      in_app("app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build).to be_empty
      end
    end
  end

  describe "owner reopen (association getter)" do
    it "returns the owner-specific proxy from the has_many getter, passing self" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "Post.rb")

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
        proxy = source_of(described_class.new(app_dir: dir).build, "Post_Assignment.rb")

        expect(proxy).to include("class Post_Assignment::ActiveRecord_Associations_CollectionProxy\n")
        # initialize(klass, owner) matches the real constructor arity; owner captured.
        expect(proxy).to match(/def initialize\(klass, owner\)\n\s*@owner = owner\n\s*end/)
        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        # build establishes the inverse belongs_to (`post`) from the owner.
        expect(proxy).to match(/def build\(\*\)\n\s*record = Assignment\.new\n\s*record\.post = owner\n\s*record\n\s*end/)
        # create / create! = build (no args, matches the optional overload) + save.
        expect(proxy).to match(/def create\(\*\)\n\s*record = build\n\s*record\.save\n\s*record\n\s*end/)
        expect(proxy).to match(/def create!\(\*\)\n\s*record = build\n\s*record\.save\n\s*record\n\s*end/)
        expect(Prism.parse(proxy).success?).to be(true)
      end
    end

    it "names the proxy <Owner>_<Element> to match rbs_rails" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build.map(&:filename)).to include("Post_Assignment.rb")
      end
    end

    it "sets the inverse belongs_to whose target is the owner" do
      # Assignment belongs_to :post AND :owner(User); the has_many owner is Post,
      # so the inverse the proxy sets is `post`, not `owner`.
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "Post_Assignment.rb")
        expect(proxy).to include("record.post = owner")
        expect(proxy).not_to include("record.owner = owner")
      end
    end

    it "emits no proxy when the element has no before_validation callback" do
      plain = "class Assignment < ApplicationRecord\n  belongs_to :post\nend\n"
      in_app("app/models/assignment.rb" => plain, "app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build).to be_empty
      end
    end
  end

  describe "RBS for invented methods" do
    it "declares run_before_validation_callbacks (not a real Rails method) in RBS" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        rbs = source_of(described_class.new(app_dir: dir).build, "Assignment.rbs")
        expect(rbs).to match(/class Assignment\n\s*def run_before_validation_callbacks: \(\) -> void\n\s*end/)
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
        expect(Dir.children(out).sort).to eq(["Assignment.rb", "Assignment.rbs", "Post.rb", "Post_Assignment.rb"])
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
