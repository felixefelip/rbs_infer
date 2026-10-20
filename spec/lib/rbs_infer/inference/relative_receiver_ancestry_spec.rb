# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a call site reaching an inherited method through a relative receiver" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def write_builder
    write("app/builder.rb", <<~RUBY)
      module X
        class Builder
          def self.build(name)
            name
          end

          def make(name)
            name
          end
        end

        class Sub < Builder
        end

        class Other
          def self.build(name)
            name
          end
        end
      end
    RUBY
    write("sig/generated/builder.rbs", <<~RBS)
      module X
        class Builder
          def self.build: (untyped name) -> untyped
          def make: (untyped name) -> untyped
        end

        class Sub < Builder
        end

        class Other
          def self.build: (untyped name) -> untyped
        end
      end
    RBS
  end

  def builder_rbs
    RbsInfer::Analyzer.new(target_class: "X::Builder", target_file: "app/builder.rb",
                           source_files: Dir["app/*.rb"]).generate_rbs
  end

  it "types a class method called on a subclass named relative to the caller's namespace" do
    write_builder
    write("app/use.rb", <<~RUBY)
      module X
        class Use
          def self.run = Sub.build(:a)
        end
      end
    RUBY

    expect(builder_rbs).to include("def self.build: (:a name)")
  end

  it "types an instance method called on an instance of a subclass named relative to the caller's namespace" do
    write_builder
    write("app/use.rb", <<~RUBY)
      module X
        class Use
          def self.run = Sub.new.make(:b)
        end
      end
    RUBY

    expect(builder_rbs).to include("def make: (:b name)")
  end

  it "leaves the parameter untyped when the relative name resolves to a class that defines its own method" do
    write_builder
    write("app/use.rb", <<~RUBY)
      module X
        class Use
          def self.run = Other.build(:c)
        end
      end
    RUBY

    expect(builder_rbs).to include("def self.build: (untyped name) -> untyped")
  end
end
