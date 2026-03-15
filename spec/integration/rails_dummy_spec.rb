# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rails dummy app integration", :dummy_app do
  let(:source_files) { Dir["app/**/*.rb"] }

  describe "User model" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "User",
        target_file: "app/models/user.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class User")
    end

    it "infers attr_accessor types" do
      expect(rbs).to include("session_token")
    end

    it "infers method return types" do
      expect(rbs).to include("def full_name")
    end

    it "includes active? predicate" do
      expect(rbs).to include("def active?")
    end
  end

  describe "Post model" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "Post",
        target_file: "app/models/post.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class Post")
    end

    it "infers summary method" do
      expect(rbs).to include("def summary")
    end

    it "infers author_name method" do
      expect(rbs).to include("def author_name")
    end

    it "infers publish! method" do
      expect(rbs).to include("def publish!")
    end

    it "infers add_comment method with keyword args" do
      expect(rbs).to include("def add_comment")
    end
  end

  describe "PostsController" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "PostsController",
        target_file: "app/controllers/posts_controller.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class PostsController")
    end

    it "includes controller actions" do
      expect(rbs).to include("def index")
      expect(rbs).to include("def show")
      expect(rbs).to include("def create")
    end

    it "includes private methods" do
      expect(rbs).to include("def set_post")
      expect(rbs).to include("def post_params")
    end
  end

  describe "PostPublisher service" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "PostPublisher",
        target_file: "app/services/post_publisher.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class PostPublisher")
    end

    it "infers initialize parameters" do
      expect(rbs).to include("def initialize")
    end

    it "infers attr_reader types" do
      expect(rbs).to include("post")
      expect(rbs).to include("notifier")
    end

    it "infers call method" do
      expect(rbs).to include("def call")
    end

    it "infers publish class method" do
      expect(rbs).to include("def publish")
    end
  end

  describe "EmailNotifier service" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "EmailNotifier",
        target_file: "app/services/email_notifier.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class EmailNotifier")
    end

    it "infers initialize with keyword args" do
      expect(rbs).to include("def initialize")
    end

    it "infers notify method" do
      expect(rbs).to include("def notify")
    end
  end

  describe "Comment model" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "Comment",
        target_file: "app/models/comment.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class Comment")
    end
  end

  describe "Tag model" do
    subject(:rbs) do
      RbsInfer::Analyzer.new(
        target_class: "Tag",
        target_file: "app/models/tag.rb",
        source_files: source_files
      ).generate_rbs
    end

    it "generates RBS output" do
      expect(rbs).to be_a(String)
      expect(rbs).to include("class Tag")
    end

    it "infers popular class method" do
      expect(rbs).to include("def popular")
    end
  end
end
