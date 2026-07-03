require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/belongs_to_default_generator"
require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe RbsInfer::Extensions::Rails::BelongsToDefaultGenerator do
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

        src = result.expanded_source
        # The lifecycle chain reproduces the example.rb contract shape.
        expect(src).to include("def save; run_before_validation_callbacks; end")
        expect(src).to include("def run_before_validation_callbacks; run_belongs_to_default_callbacks; end")
        # The lambda BODY is inlined directly (not `-> {}.call`).
        expect(src).to include("self.owner = post.user")
        expect(Prism.parse(src).success?).to be(true)

        entry = result.source_map.fetch(0)
        expect(entry["original_path"]).to eq("app/models/assignment.rb")
        expect(entry["original_line"]).to eq(3) # the `belongs_to :owner ...` line
        # The mapped span points at the lambda body `post.user`.
        expect(ASSIGNMENT.lines[entry["original_line"] - 1][entry["original_column"], entry["original_length"]])
          .to eq("post.user")
        # The expansion line it stands in for holds the inlined body.
        expect(src.lines[entry["expanded_line"] - 1]).to include("self.owner = post.user")
      end
    end

    it "synthesizes the deref-receiver target with a stub for the called method" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        src = described_class.new(app_dir: dir).build.expanded_source

        # `post` (a Post) has `.user` called on it → Post gets a `user` stub.
        expect(src).to match(/class RbsInferBelongsToDefaultPost\n\s*def user; raise; end\n\s*end/)
        # `User` is a belongs_to target constructed by the witness → it exists.
        expect(src).to include("class RbsInferBelongsToDefaultUser")
      end
    end

    it "uses camelCase (never underscored) synthetic names" do
      # An underscore in a constant defeats the analyzer's external-setter
      # resolution, typing every attr `untyped` — so the names must be
      # camelCase for the nilable `T?` inference the contract relies on.
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        src = described_class.new(app_dir: dir).build.expanded_source
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
        src = described_class.new(app_dir: dir).build.expanded_source

        # The site sets the inverse belongs_to (`post`) from the association
        # OWNER (a Post), then saves — the safe path.
        expect(src).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*owner = RbsInferBelongsToDefaultPost\.new\n\s*record\.post = owner\n\s*record\.save/)
      end
    end

    it "emits no site when there is no construction call, but still emits the witness" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        src = described_class.new(app_dir: dir).build.expanded_source

        expect(src).not_to include("def self.site_1")
        # The witness seeds the belongs_to external-setter types regardless.
        expect(src).to include("def self.witness_assignment")
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
        src = described_class.new(app_dir: dir).build.expanded_source

        # `owner: User.new` is a provably non-nil literal → it narrows `owner`.
        expect(src).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*record\.owner = RbsInferBelongsToDefaultUser\.new\n\s*record\.save/)
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
        src = described_class.new(app_dir: dir).build.expanded_source

        # A ParamsBag arg proves nothing → the site sets no belongs_to and
        # just saves, so the default's deref stays (soundly) flaggable.
        expect(src).to match(/def self\.site_1\n\s*record = RbsInferBelongsToDefaultAssignment\.new\n\s*record\.save/)
      end
    end
  end

  describe "#generate (disk)" do
    it "writes both sidecars only when a default: is present" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        expanded, sidecar = described_class.new(app_dir: dir).generate

        expect(File.exist?(expanded)).to be(true)
        expect(File.exist?(sidecar)).to be(true)
        expect(YAML.safe_load(File.read(sidecar)).first["original_path"]).to eq("app/models/assignment.rb")
      end
    end

    it "removes stale sidecars when nothing qualifies" do
      in_app("app/models/plain.rb" => "class Plain < ApplicationRecord\n  belongs_to :user\nend\n") do |dir|
        expanded = File.join(dir, described_class::EXPANDED_PATH)
        sidecar = File.join(dir, described_class::SIDECAR_PATH)
        FileUtils.mkdir_p(File.dirname(expanded))
        File.write(expanded, "stale")
        File.write(sidecar, "stale")

        described_class.new(app_dir: dir).generate
        expect(File.exist?(expanded)).to be(false)
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
