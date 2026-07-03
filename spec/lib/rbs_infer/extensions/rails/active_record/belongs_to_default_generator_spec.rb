require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/active_record/belongs_to_default_generator"
require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe RbsInfer::Extensions::Rails::ActiveRecord::BelongsToDefaultGenerator do
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

  # Fetch one synthetic file's source by class name from a build Result.
  def file_source(result, class_name)
    result.files.find { |f| f.class_name == class_name }&.source
  end

  # The canonical Fizzy shape: a required `belongs_to :post` and a
  # `belongs_to :owner, default: -> { post.user }`, built through the safe
  # `@post.assignments.create!` association path.
  ASSIGNMENT = <<~RUBY
    class Assignment < ApplicationRecord
      belongs_to :post
      belongs_to :owner, class_name: "User", default: -> { post.user }
    end
  RUBY

  POST = <<~RUBY
    class Post < ApplicationRecord
      has_many :assignments, dependent: :destroy
    end
  RUBY

  CONTROLLER = <<~RUBY
    class Posts::AssignmentsController < ApplicationController
      def create
        @assignment = @post.assignments.create!(assignment_params)
      end
    end
  RUBY

  describe "#build (model-side expansion)" do
    it "inlines the default lambda into a save-reachable callback and maps it back" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        result = described_class.new(app_dir: dir).build

        model = file_source(result, "Assignment")
        # The lifecycle chain reproduces the example.rb contract shape, emitted
        # multi-line (not one-liners).
        expect(model).to include("  def save\n    run_before_validation_callbacks\n  end")
        expect(model).to include("  def run_before_validation_callbacks\n    run_belongs_to_default_callbacks\n  end")
        # The lambda BODY is inlined directly (not `-> {}.call`).
        expect(model).to include("self.owner = post.user")

        result.files.each { |f| expect(Prism.parse(f.source).success?).to be(true) }

        entry = result.source_map.fetch(0)
        expect(entry["expanded_file"]).to eq("RbsInferBelongsToDefaultAssignment.rb")
        expect(entry["original_path"]).to eq("app/models/assignment.rb")
        expect(entry["original_line"]).to eq(3) # the `belongs_to :owner ...` line
        # The mapped span points at the lambda body `post.user`.
        expect(ASSIGNMENT.lines[entry["original_line"] - 1][entry["original_column"], entry["original_length"]])
          .to eq("post.user")
        # The expansion line it stands in for holds the inlined body.
        expect(model.lines[entry["expanded_line"] - 1]).to include("self.owner = post.user")
      end
    end

    it "emits one file per synthetic class" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        result = described_class.new(app_dir: dir).build

        expect(result.files.map(&:filename)).to contain_exactly(
          "RbsInferBelongsToDefaultPost.rb",
          "RbsInferBelongsToDefaultUser.rb",
          "RbsInferBelongsToDefaultAssignment.rb",
          "RbsInferBelongsToDefaultRunner.rb"
        )
      end
    end

    it "synthesizes the deref-receiver target with a stub for the called method" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        result = described_class.new(app_dir: dir).build

        # `post` (a Post) has `.user` called on it → Post gets a `user` stub.
        expect(file_source(result, "Post")).to match(/class RbsInferBelongsToDefaultPost\n  def user\n    raise\n  end\nend/)
        # `User` is a belongs_to target constructed by the witness → it exists.
        expect(file_source(result, "User")).to include("class RbsInferBelongsToDefaultUser")
      end
    end

    it "uses camelCase (never underscored) synthetic names" do
      # An underscore in a constant defeats the analyzer's external-setter
      # resolution, typing every attr `untyped` — so the names must be
      # camelCase for the nilable `T?` inference the contract relies on.
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        src = described_class.new(app_dir: dir).build.combined_source
        synthetic = src.scan(/RbsInferBelongsToDefault\w*/).uniq
        expect(synthetic).to all(satisfy { |name| !name.include?("_") })
      end
    end
  end

  describe "#build (caller-side construction)" do
    it "expands `owner.assoc.create!` into build + owner-setter + save" do
      in_app(
        "app/models/assignment.rb" => ASSIGNMENT,
        "app/models/post.rb" => POST,
        "app/controllers/posts/assignments_controller.rb" => CONTROLLER
      ) do |dir|
        runner = file_source(described_class.new(app_dir: dir).build, "Runner")

        # The site sets the inverse belongs_to (`post`) from the association
        # OWNER (a Post), then saves — the safe path.
        expect(runner).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*owner = RbsInferBelongsToDefaultPost\.new\n\s*record\.post = owner\n\s*record\.save/)
      end
    end

    it "emits no site when there is no construction call, but still emits the witness" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        runner = file_source(described_class.new(app_dir: dir).build, "Runner")

        expect(runner).not_to include("def self.site_1")
        # The witness seeds the belongs_to external-setter types regardless.
        expect(runner).to include("def self.witness_assignment")
      end
    end

    it "sets only non-nil literal belongs_to kwargs on a direct construction" do
      direct = <<~RUBY
        class Service
          def run
            Assignment.create!(owner: User.new)
          end
        end
      RUBY
      in_app(
        "app/models/assignment.rb" => ASSIGNMENT,
        "app/models/post.rb" => POST,
        "app/services/service.rb" => direct
      ) do |dir|
        runner = file_source(described_class.new(app_dir: dir).build, "Runner")

        # `owner: User.new` is a provably non-nil literal → it narrows `owner`.
        expect(runner).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*record\.owner = RbsInferBelongsToDefaultUser\.new\n\s*record\.save/)
      end
    end

    it "leaves params-sourced attrs nilable on a direct construction (no setter)" do
      direct = <<~RUBY
        class Service
          def run
            Assignment.create!(assignment_params)
          end
        end
      RUBY
      in_app(
        "app/models/assignment.rb" => ASSIGNMENT,
        "app/models/post.rb" => POST,
        "app/services/service.rb" => direct
      ) do |dir|
        runner = file_source(described_class.new(app_dir: dir).build, "Runner")

        # A ParamsBag arg proves nothing → the site sets no belongs_to and
        # just saves, so the default's deref stays (soundly) flaggable.
        expect(runner).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*record\.save/)
      end
    end
  end

  describe "#generate (disk)" do
    it "writes the expansion directory + source-map only when a default: is present" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        expanded_dir, sidecar = described_class.new(app_dir: dir).generate

        expect(File.directory?(expanded_dir)).to be(true)
        expect(Dir.children(expanded_dir)).to include("RbsInferBelongsToDefaultAssignment.rb")
        expect(File.exist?(sidecar)).to be(true)
        expect(YAML.safe_load(File.read(sidecar)).first["original_path"]).to eq("app/models/assignment.rb")
      end
    end

    it "removes stale output when nothing qualifies" do
      in_app("app/models/plain.rb" => "class Plain < ApplicationRecord\n  belongs_to :user\nend\n") do |dir|
        expanded_dir = File.join(dir, described_class::EXPANDED_DIR)
        sidecar = File.join(dir, described_class::SIDECAR_PATH)
        FileUtils.mkdir_p(expanded_dir)
        File.write(File.join(expanded_dir, "Stale.rb"), "stale")
        File.write(sidecar, "stale")

        described_class.new(app_dir: dir).generate
        expect(File.exist?(expanded_dir)).to be(false)
        expect(File.exist?(sidecar)).to be(false)
      end
    end

    it "returns nil from #build when no model declares a default:" do
      in_app("app/models/plain.rb" => "class Plain < ApplicationRecord\n  belongs_to :user\nend\n") do |dir|
        expect(described_class.new(app_dir: dir).build).to be_nil
      end
    end
  end
end
