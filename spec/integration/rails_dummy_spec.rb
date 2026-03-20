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

  def generate_rbs(target_class:, target_file:)
    RbsInfer::Analyzer.new(
      target_class: target_class,
      target_file: target_file,
      source_files: source_files
    ).generate_rbs
  end

  def expected_rbs(name)
    expectations_dir.join("#{name}.rbs").read
  end

  # To regenerate expectations after intentional changes:
  #   UPDATE_EXPECTATIONS=1 bundle exec rspec spec/integration/
  def assert_snapshot(name, target_class:, target_file:)
    rbs = generate_rbs(target_class: target_class, target_file: target_file)

    if ENV["UPDATE_EXPECTATIONS"]
      expectations_dir.join("#{name}.rbs").write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "User model matches expected RBS" do
    assert_snapshot("user", target_class: "User", target_file: "app/models/user.rb")
  end

  it "Post model matches expected RBS" do
    assert_snapshot("post", target_class: "Post", target_file: "app/models/post.rb")
  end

  it "Comment model matches expected RBS" do
    assert_snapshot("comment", target_class: "Comment", target_file: "app/models/comment.rb")
  end

  it "Tag model matches expected RBS" do
    assert_snapshot("tag", target_class: "Tag", target_file: "app/models/tag.rb")
  end

  it "PostTag model matches expected RBS" do
    assert_snapshot("post_tag", target_class: "PostTag", target_file: "app/models/post_tag.rb")
  end

  it "PostsController matches expected RBS" do
    assert_snapshot("posts_controller", target_class: "PostsController", target_file: "app/controllers/posts_controller.rb")
  end

  it "UsersController matches expected RBS" do
    assert_snapshot("users_controller", target_class: "UsersController", target_file: "app/controllers/users_controller.rb")
  end

  it "PostPublisher service matches expected RBS" do
    assert_snapshot("post_publisher", target_class: "PostPublisher", target_file: "app/services/post_publisher.rb")
  end

  it "EmailNotifier service matches expected RBS" do
    assert_snapshot("email_notifier", target_class: "EmailNotifier", target_file: "app/services/email_notifier.rb")
  end

  it "TagDestroy service matches expected RBS" do
    assert_snapshot("tag_destroy", target_class: "TagDestroy", target_file: "app/services/tag_destroy.rb")
  end

  it "ParseXml service matches expected RBS" do
    assert_snapshot("parse_xml", target_class: "ParseXml", target_file: "app/services/parse_xml.rb")
  end

  it "Post::Taggable concern matches expected RBS" do
    assert_snapshot("post/taggable", target_class: "Post::Taggable", target_file: "app/models/post/taggable.rb")
  end

  it "Post::Notifiable concern matches expected RBS" do
    assert_snapshot("post/notifiable", target_class: "Post::Notifiable", target_file: "app/models/post/notifiable.rb")
  end

  it "User::Recoverable concern matches expected RBS" do
    assert_snapshot("user/recoverable", target_class: "User::Recoverable", target_file: "app/models/user/recoverable.rb")
  end

  it "User::Displayable concern matches expected RBS" do
    assert_snapshot("user/displayable", target_class: "User::Displayable", target_file: "app/models/user/displayable.rb")
  end

  it "ApplicationController rails_custom matches expected RBS" do
    require "rbs_infer/rails_custom_generator"
    require "tmpdir"
    Dir.mktmpdir do |tmpdir|
      generator = RbsInfer::RailsCustom::Generator.new(output_dir: tmpdir)
      generator.generate_all
      rbs = File.read(File.join(tmpdir, "application_controller.rbs"))

      if ENV["UPDATE_EXPECTATIONS"]
        expectations_dir.join("application_controller.rbs").write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs("application_controller").chomp)
    end
  end
end
