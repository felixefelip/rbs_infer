# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "the block requirement of a method that forwards its block" do
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

  def write_library
    write("sig/vendor/lib.rbs", <<~RBS)
      class Builder
        def self.build: (untyped name) { () -> untyped } -> untyped
        def self.create: (untyped name) { () -> untyped } -> untyped
      end
    RBS
    write("lib/builder.rb", <<~RUBY)
      class Builder
        # @rbs_infer |...
        def self.build(name, &block)
          create(name, &block)
        end

        # @rbs_infer |...
        def self.create(name, &block)
          name
        end
      end
    RUBY
  end

  def build_signature
    rbs = RbsInfer::Analyzer.new(target_file: "lib/builder.rb", source_files: Dir["lib/*.rb"]).generate_rbs
    rbs[/def self\.build: .*/]
  end

  it "is not taken from a library signature that requires a block the callee's body leaves optional" do
    write_library
    write("sig/generated/lib/builder.rbs", <<~RBS)
      class Builder
        def self.create: (untyped name) ?{ (*untyped) -> untyped } -> untyped | ...
      end
    RBS

    expect(build_signature).to include("?{ (*untyped) -> untyped }")
  end

  it "is not held by the forwarder's own earlier output" do
    write_library
    write("sig/generated/lib/builder.rbs", <<~RBS)
      class Builder
        def self.build: (untyped name) { () -> untyped } -> untyped | ...
        def self.create: (untyped name) ?{ (*untyped) -> untyped } -> untyped | ...
      end
    RBS

    expect(build_signature).to include("?{ (*untyped) -> untyped }")
  end
end
