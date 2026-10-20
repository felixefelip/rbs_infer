# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a bare call reaching a method of a module nested in the target" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before do
    RbsInfer::Signatures::RbsTypeLookup.reset!
    RbsInfer::Signatures::SteepEnvironment.reset!
    RbsInfer::Project::Corpus.reset!
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def write_macros
    write("lib/macros.rb", <<~RUBY)
      module X
        module Assoc
          module ClassMethods
            def declare(name)
              name
            end
          end
        end
      end
    RUBY
  end

  def declare_signature
    rbs = RbsInfer::Analyzer.new(target_file: "lib/macros.rb", source_files: Dir["{lib,app}/*.rb"]).generate_rbs
    rbs[/def declare: .*/]
  end

  it "is read from a class that extends the module" do
    write_macros
    write("app/post.rb", <<~RUBY)
      class Post
        extend X::Assoc::ClassMethods
        declare :comments
      end
    RUBY

    expect(declare_signature).to start_with("def declare: (:comments name)")
  end

  it "is read from a class that names the module relative to its namespace" do
    write_macros
    write("app/post.rb", <<~RUBY)
      module X
        class Post
          extend Assoc::ClassMethods
          declare :comments
        end
      end
    RUBY

    expect(declare_signature).to start_with("def declare: (:comments name)")
  end

  it "is read from a subclass of a class declared only in RBS that extends the module" do
    write_macros
    write("app/post.rb", <<~RUBY)
      class Post < Base
        declare :comments
      end
    RUBY
    write("sig/vendor/base.rbs", <<~RBS)
      class Base
        extend X::Assoc::ClassMethods
      end
    RBS
    write("sig/generated/app/post.rbs", <<~RBS)
      class Post < Base
      end
    RBS
    write("sig/generated/lib/macros.rbs", <<~RBS)
      module X
        module Assoc
          module ClassMethods
            def declare: (untyped name) -> untyped
          end
        end
      end
    RBS

    expect(declare_signature).to start_with("def declare: (:comments name)")
  end

  it "is not read from a class the module never reaches" do
    write_macros
    write("app/post.rb", <<~RUBY)
      class Post
        declare :comments
      end
    RUBY

    expect(declare_signature).to start_with("def declare: (untyped name)")
  end
end
