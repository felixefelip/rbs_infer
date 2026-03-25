# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/concern_annotation_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::ConcernAnnotationGenerator do
  def generator(dir, files = nil)
    described_class.new(app_dir: dir, source_files: files || Dir["#{dir}/**/*.rb"])
  end

  def write_file(dir, path, content)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  def read_file(path)
    File.read(path)
  end

  around do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  describe "concerns (extend ActiveSupport::Concern)" do
    it "injects both @type self and @type instance after extend line" do
      file = write_file(@tmpdir, "post/taggable.rb", <<~RUBY)
        module Post::Taggable
          extend ActiveSupport::Concern

          def tag_names
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      result = read_file(file)
      expect(result).to include("# @type self: singleton(Post) & singleton(Post::Taggable)")
      expect(result).to include("# @type instance: Post & Post::Taggable")
    end

    it "places annotations after the extend line, before the rest of the body" do
      file = write_file(@tmpdir, "post/taggable.rb", <<~RUBY)
        module Post::Taggable
          extend ActiveSupport::Concern

          included do
            has_many :tags
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      lines = read_file(file).lines
      extend_idx = lines.index { |l| l.include?("extend ActiveSupport::Concern") }
      self_idx   = lines.index { |l| l.include?("@type self:") }
      instance_idx = lines.index { |l| l.include?("@type instance:") }
      included_idx = lines.index { |l| l.include?("included do") }

      expect(self_idx).to be > extend_idx
      expect(instance_idx).to be > self_idx
      expect(included_idx).to be > instance_idx
    end

    it "infers including class from module namespace" do
      file = write_file(@tmpdir, "user/recoverable.rb", <<~RUBY)
        module User::Recoverable
          extend ActiveSupport::Concern
        end
      RUBY

      generator(@tmpdir).generate_all

      result = read_file(file)
      expect(result).to include("singleton(User) & singleton(User::Recoverable)")
      expect(result).to include("@type instance: User & User::Recoverable")
    end

    it "does not inject @type self into plain modules" do
      file = write_file(@tmpdir, "post/taggable.rb", <<~RUBY)
        module Post::Taggable
          def tag_names
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      result = read_file(file)
      expect(result).not_to include("@type self:")
      expect(result).to include("@type instance: Post & Post::Taggable")
    end
  end

  describe "plain modules (no extend ActiveSupport::Concern)" do
    it "injects only @type instance after the module line" do
      file = write_file(@tmpdir, "post/formatter.rb", <<~RUBY)
        module Post::Formatter
          def format_title
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      result = read_file(file)
      expect(result).to include("# @type instance: Post & Post::Formatter")
      expect(result).not_to include("@type self:")
    end

    it "places annotation as the first line inside the module" do
      file = write_file(@tmpdir, "post/formatter.rb", <<~RUBY)
        module Post::Formatter
          def format_title
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      lines = read_file(file).lines
      module_idx   = lines.index { |l| l.include?("module Post::Formatter") }
      instance_idx = lines.index { |l| l.include?("@type instance:") }

      expect(instance_idx).to eq(module_idx + 1)
    end
  end

  describe "idempotency" do
    it "does not modify a concern that is already annotated" do
      source = <<~RUBY
        module Post::Taggable
          extend ActiveSupport::Concern

          # @type self: singleton(Post) & singleton(Post::Taggable)
          # @type instance: Post & Post::Taggable

          def tag_names
          end
        end
      RUBY

      file = write_file(@tmpdir, "post/taggable.rb", source)
      generator(@tmpdir).generate_all

      expect(read_file(file)).to eq(source)
    end

    it "does not modify a plain module that is already annotated" do
      source = <<~RUBY
        module Post::Formatter
          # @type instance: Post & Post::Formatter

          def format_title
          end
        end
      RUBY

      file = write_file(@tmpdir, "post/formatter.rb", source)
      generator(@tmpdir).generate_all

      expect(read_file(file)).to eq(source)
    end
  end

  describe "Strategy B: include scanning for unnamespaced modules" do
    it "resolves including class by scanning for include calls" do
      write_file(@tmpdir, "post.rb", <<~RUBY)
        class Post
          include Taggable
        end
      RUBY

      file = write_file(@tmpdir, "taggable.rb", <<~RUBY)
        module Taggable
          def tag_names
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      expect(read_file(file)).to include("# @type instance: Post & Taggable")
    end

    it "skips an unnamespaced module with no discoverable includer" do
      source = <<~RUBY
        module Orphan
          def something
          end
        end
      RUBY

      file = write_file(@tmpdir, "orphan.rb", source)
      generator(@tmpdir).generate_all

      expect(read_file(file)).to eq(source)
    end
  end

  describe "multiple modules in one file" do
    it "annotates each module independently" do
      file = write_file(@tmpdir, "post/mixed.rb", <<~RUBY)
        module Post::Taggable
          extend ActiveSupport::Concern

          def tag_names
          end
        end

        module Post::Formatter
          def format_title
          end
        end
      RUBY

      generator(@tmpdir).generate_all

      result = read_file(file)
      expect(result).to include("@type self: singleton(Post) & singleton(Post::Taggable)")
      expect(result).to include("@type instance: Post & Post::Taggable")
      expect(result).to include("@type instance: Post & Post::Formatter")
      expect(result).not_to match(/Post::Formatter.*@type self:/m)
    end
  end
end
