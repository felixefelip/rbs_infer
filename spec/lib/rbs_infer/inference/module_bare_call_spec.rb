# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "A bare call in a module's method" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end

  before do
    RbsInfer::Signatures::RbsTypeLookup.reset!
    RbsInfer::Project::Corpus.reset!
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def base_rbs
    RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"]).generate_rbs
  end

  before do
    write("app/base.rb", "class Base\n  def lookup(name) = name\nend\n")
    write("app/post.rb", "class Post < Base\nend\n")
    write("app/caller.rb", "Post.new.comments\n")
  end

  it "is a call site of the method the module's includer inherits" do
    write("app/generated.rb", <<~RUBY)
      class Post
        module Generated
          def comments
            lookup(:comments)
          end
        end
        include Generated
      end
    RUBY
    write("sig/generated/app.rbs", <<~RBS)
      class Base
        def lookup: (untyped name) -> untyped
      end
      class Post < Base
        module Generated
          def comments: () -> untyped
        end
        include Generated
      end
    RBS

    expect(base_rbs).to include("def lookup: (:comments name)")
  end

  it "is not one when the includer defines the method itself" do
    write("app/generated.rb", <<~RUBY)
      class Post
        def lookup(name) = name
        module Generated
          def comments
            lookup(:comments)
          end
        end
        include Generated
      end
    RUBY
    write("sig/generated/app.rbs", <<~RBS)
      class Base
        def lookup: (untyped name) -> untyped
      end
      class Post < Base
        def lookup: (untyped name) -> untyped
        module Generated
          def comments: () -> untyped
        end
        include Generated
      end
    RBS

    expect(base_rbs).to include("def lookup: (untyped name)")
  end
end
