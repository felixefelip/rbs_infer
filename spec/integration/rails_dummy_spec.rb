# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rails dummy app integration", :dummy_app do
  let(:source_files) { Dir["app/**/*.rb"] }
  let(:expectations_dir) { Pathname.new(File.expand_path("../expectations", __dir__)) }

  # Generate sig/rbs_rails/ types once before running snapshot tests
  before(:all) do
    Dir.chdir(DUMMY_APP_ROOT) do
      Bundler.with_unbundled_env do
        system("bundle", "install", "--quiet", exception: true)
        system("bundle", "exec", "rake", "db:create", "db:migrate", "RAILS_ENV=development", exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rake", "rbs_rails:all", exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rbs", "collection", "install", exception: true, out: File::NULL, err: File::NULL)
      end
    end
  end

  def generate_rbs(target_class:, target_file:, **kwargs)
    RbsInfer::Analyzer.new(
      target_class: target_class,
      target_file: target_file,
      source_files: source_files,
      **kwargs
    ).generate_rbs
  end

  def expected_rbs(name)
    expectations_dir.join("#{name}.rbs").read
  end

  # To regenerate expectations after intentional changes:
  #   UPDATE_EXPECTATIONS=1 bundle exec rspec spec/integration/
  def assert_snapshot(name, target_class:, target_file:, **kwargs)
    rbs = generate_rbs(target_class: target_class, target_file: target_file, **kwargs)

    if ENV["UPDATE_EXPECTATIONS"]
      expectations_dir.join("#{name}.rbs").write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "User model matches expected RBS" do
    assert_snapshot("models/user", target_class: "User", target_file: "app/models/user.rb")
  end

  it "Post model matches expected RBS" do
    assert_snapshot("models/post", target_class: "Post", target_file: "app/models/post.rb")
  end

  it "Comment model matches expected RBS" do
    assert_snapshot("models/comment", target_class: "Comment", target_file: "app/models/comment.rb")
  end

  it "Tag model matches expected RBS" do
    assert_snapshot("models/tag", target_class: "Tag", target_file: "app/models/tag.rb")
  end

  it "PostTag model matches expected RBS" do
    assert_snapshot("models/post_tag", target_class: "PostTag", target_file: "app/models/post_tag.rb")
  end

  it "PostsController matches expected RBS" do
    assert_snapshot("controllers/posts_controller", target_class: "PostsController", target_file: "app/controllers/posts_controller.rb")
  end

  it "UsersController matches expected RBS" do
    assert_snapshot("controllers/users_controller", target_class: "UsersController", target_file: "app/controllers/users_controller.rb")
  end

  it "PostPublisher service matches expected RBS" do
    assert_snapshot("services/post_publisher", target_class: "PostPublisher", target_file: "app/services/post_publisher.rb")
  end

  it "EmailNotifier service matches expected RBS" do
    assert_snapshot("services/email_notifier", target_class: "EmailNotifier", target_file: "app/services/email_notifier.rb")
  end

  it "TagDestroy service matches expected RBS" do
    assert_snapshot("services/tag_destroy", target_class: "TagDestroy", target_file: "app/services/tag_destroy.rb")
  end

  it "ParseXml service matches expected RBS" do
    assert_snapshot("services/parse_xml", target_class: "ParseXml", target_file: "app/services/parse_xml.rb")
  end

  it "Post::Taggable concern matches expected RBS" do
    assert_snapshot("models/post/taggable", target_class: "Post::Taggable", target_file: "app/models/post/taggable.rb")
  end

  it "Post::Notifiable concern matches expected RBS" do
    assert_snapshot("models/post/notifiable", target_class: "Post::Notifiable", target_file: "app/models/post/notifiable.rb")
  end

  it "User::Recoverable concern matches expected RBS" do
    assert_snapshot("models/user/recoverable", target_class: "User::Recoverable", target_file: "app/models/user/recoverable.rb")
  end

  it "User::Displayable concern matches expected RBS" do
    assert_snapshot("models/user/displayable", target_class: "User::Displayable", target_file: "app/models/user/displayable.rb")
  end

  it "Test::Filtrable concern matches expected RBS" do
    assert_snapshot("models/concerns/test/filtrable", target_class: "Test::Filtrable", target_file: "app/models/concerns/test/filtrable.rb")
  end

  it "ApplicationHelper matches expected RBS" do
    require "rbs_infer/extensions/rails/erb_caller_resolver"
    erb_resolver = RbsInfer::Extensions::Rails::ErbCallerResolver.new(app_dir: Dir.pwd, source_files: source_files)
    assert_snapshot("helpers/application_helper", target_class: "ApplicationHelper", target_file: "app/helpers/application_helper.rb", extra_caller_sources: erb_resolver)
  end

  it "PostsHelper matches expected RBS" do
    require "rbs_infer/extensions/rails/erb_caller_resolver"
    erb_resolver = RbsInfer::Extensions::Rails::ErbCallerResolver.new(app_dir: Dir.pwd, source_files: source_files)
    assert_snapshot("helpers/posts_helper", target_class: "PostsHelper", target_file: "app/helpers/posts_helper.rb", extra_caller_sources: erb_resolver)
  end

  it "ApplicationController rails_custom matches expected RBS" do
    require "rbs_infer/extensions/rails/custom_generator"
    require "tmpdir"
    Dir.mktmpdir do |tmpdir|
      generator = RbsInfer::Extensions::Rails::CustomGenerator.new(
        output_dir: tmpdir,
        app_dir: Dir.pwd,
        source_files: source_files
      )
      generator.generate_all
      rbs = File.read(File.join(tmpdir, "application_controller.rbs"))

      if ENV["UPDATE_EXPECTATIONS"]
        expectations_dir.join("controllers/application_controller.rbs").write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs("controllers/application_controller").chomp)
    end
  end

  it "ActionViewContext rails_custom matches expected RBS" do
    require "rbs_infer/extensions/rails/custom_generator"
    require "tmpdir"
    Dir.mktmpdir do |tmpdir|
      generator = RbsInfer::Extensions::Rails::CustomGenerator.new(
        output_dir: tmpdir,
        app_dir: Dir.pwd,
        source_files: source_files
      )
      generator.generate_all
      rbs = File.read(File.join(tmpdir, "action_view_context.rbs"))

      if ENV["UPDATE_EXPECTATIONS"]
        expectations_dir.join("rails_custom_action_view_context.rbs").write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs("rails_custom_action_view_context").chomp)
    end
  end

  describe "ERB convention generator" do
    let(:erb_generator) do
      require "rbs_infer/extensions/rails/erb_convention_generator"
      @erb_tmpdir = Dir.mktmpdir
      RbsInfer::Extensions::Rails::ErbConventionGenerator.new(
        app_dir: Dir.pwd,
        output_dir: @erb_tmpdir,
        source_files: source_files
      )
    end

    after { FileUtils.remove_entry(@erb_tmpdir) if @erb_tmpdir }

    before { erb_generator.generate_all }

    def assert_erb_snapshot(output_file:)
      rbs = File.read(File.join(@erb_tmpdir, output_file))
      snapshot_name = output_file.delete_prefix("app/").delete_suffix(".rbs")

      if ENV["UPDATE_EXPECTATIONS"]
        path = expectations_dir.join("#{snapshot_name}.rbs")
        FileUtils.mkdir_p(path.dirname)
        path.write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs(snapshot_name).chomp)
    end

    it "ERBPostsShow matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/show.rbs")
    end

    it "ERBPostsIndex matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/index.rbs")
    end

    it "ERBPostsNew matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/new.rbs")
    end

    it "ERBPostsEdit matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/edit.rbs")
    end

    it "ERBPartialPostsForm matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_form.rbs")
    end

    it "ERBPartialPostsComment matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_comment.rbs")
    end

    # _summary is rendered via shorthand: render "posts/summary", post: @post
    # (no `partial:` / `locals:` keys) — verifies shorthand render local inference
    it "ERBPartialPostsSummary matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_summary.rbs")
    end

    it "shorthand render infers local type without partial:/locals: keys" do
      rbs = File.read(File.join(@erb_tmpdir, "app/views/posts/_summary.rbs"))
      expect(rbs).to include("attr_reader post: Post")
    end

    it "shorthand render does not bleed into explicit partial:/locals: inference" do
      rbs = File.read(File.join(@erb_tmpdir, "app/views/posts/_comment.rbs"))
      expect(rbs).to include("attr_reader comment: Comment")
      expect(rbs).not_to include("post:")
    end

    it "ERBLayoutsApplication matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/layouts/application.rbs")
    end
  end
end
