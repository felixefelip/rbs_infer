require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::DependencySorter do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def write_file(relative_path, content)
    path = File.join(@tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe ".sort" do
    it "returns files with no dependencies in the first level" do
      a = write_file("app/models/user.rb", <<~RUBY)
        class User
          def name; "test"; end
        end
      RUBY

      b = write_file("app/models/post.rb", <<~RUBY)
        class Post
          def title; "test"; end
        end
      RUBY

      levels = described_class.sort([a, b])
      expect(levels.size).to eq(1)
      expect(levels[0]).to contain_exactly(a, b)
    end

    it "places dependent files after their dependencies" do
      user = write_file("app/models/user.rb", <<~RUBY)
        class User
          def name; "test"; end
        end
      RUBY

      service = write_file("app/services/create_user.rb", <<~RUBY)
        class CreateUser
          def call
            User.new(name: "Felix")
          end
        end
      RUBY

      levels = described_class.sort([service, user])
      # User should be in an earlier or same level as CreateUser
      user_level = levels.index { |l| l.include?(user) }
      service_level = levels.index { |l| l.include?(service) }
      expect(user_level).to be <= service_level
    end

    it "handles a chain of dependencies A -> B -> C" do
      c = write_file("app/models/tag.rb", <<~RUBY)
        class Tag
          def name; "tag"; end
        end
      RUBY

      b = write_file("app/services/tag_service.rb", <<~RUBY)
        class TagService
          def process
            Tag.find(1)
          end
        end
      RUBY

      a = write_file("app/services/tag_orchestrator.rb", <<~RUBY)
        class TagOrchestrator
          def run
            TagService.new.process
          end
        end
      RUBY

      levels = described_class.sort([a, b, c])

      tag_level = levels.index { |l| l.include?(c) }
      service_level = levels.index { |l| l.include?(b) }
      orch_level = levels.index { |l| l.include?(a) }

      expect(tag_level).to be < service_level
      expect(service_level).to be < orch_level
    end

    it "handles circular dependencies without infinite loop" do
      a = write_file("app/models/author.rb", <<~RUBY)
        class Author
          def books; Book.where(author: self); end
        end
      RUBY

      b = write_file("app/models/book.rb", <<~RUBY)
        class Book
          def author; Author.find(1); end
        end
      RUBY

      levels = described_class.sort([a, b])
      all_files = levels.flatten
      expect(all_files).to contain_exactly(a, b)
    end

    it "includes all input files in the output" do
      files = (1..5).map do |i|
        write_file("app/models/model#{i}.rb", "class Model#{i}; end")
      end

      levels = described_class.sort(files)
      expect(levels.flatten).to contain_exactly(*files)
    end

    it "handles files that fail to parse gracefully" do
      good = write_file("app/models/user.rb", "class User; end")
      bad = write_file("app/models/broken.rb", "")

      levels = described_class.sort([good, bad])
      expect(levels.flatten).to include(good)
    end
  end
end
