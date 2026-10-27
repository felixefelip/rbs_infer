# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a block a method passes on through super" do
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

  def child_rbs(body)
    write("sig/app/parent.rbs", <<~RBS)
      class Parent
        def required: (untyped key) { (Integer) -> untyped } -> untyped
        def optional: (untyped key) ?{ () -> untyped } -> untyped
        def blockless: (untyped key) -> untyped
      end

      class Child < Parent
        def required: (untyped key) -> untyped
        def optional: (untyped key) -> untyped
        def blockless: (untyped key) -> untyped
      end
    RBS
    source = write("app/child.rb", "class Child < Parent\n#{body}end\n")

    RbsInfer::Analyzer.new(target_class: "Child", target_file: source, source_files: [source]).generate_rbs
  end

  it "takes the block the method super reaches requires" do
    rbs = child_rbs(<<~RUBY)
      def required(key)
        [key].each { super }
      end
    RUBY

    expect(rbs).to include("def required: (untyped key) { (Integer) -> untyped } -> Array[untyped]")
  end

  it "reads an explicit super given no block the same way" do
    rbs = child_rbs(<<~RUBY)
      def required(key)
        super(key)
      end
    RUBY

    expect(rbs).to include("def required: (untyped key) { (Integer) -> untyped } -> untyped")
  end

  it "keeps the block optional when the method super reaches does" do
    rbs = child_rbs(<<~RUBY)
      def optional(key)
        super
      end
    RUBY

    expect(rbs).to include("def optional: (untyped key) ?{ (*untyped) -> untyped } -> untyped")
  end

  it "takes no block when the method super reaches takes none" do
    rbs = child_rbs(<<~RUBY)
      def blockless(key)
        super
      end
    RUBY

    expect(rbs).to include("def blockless: (untyped key) -> untyped")
  end

  it "takes no block when super is given one of its own" do
    rbs = child_rbs(<<~RUBY)
      def required(key)
        super(key) { |n| n }
      end
    RUBY

    expect(rbs).to match(/def required: \(untyped key\) -> /)
  end
end
