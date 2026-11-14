# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a block handed on as an ordinary argument" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def store_source
    <<~RUBY
      class Store
        def initialize(&fallback)
          install(fallback)
        end

        private

        def install(fallback)
          @fallback = fallback
          fallback&.call(self, Time.now)
        end
      end
    RUBY
  end

  def generate(target)
    RbsInfer::Analyzer.new(target_class: "Store", target_file: target, source_files: [target]).generate_rbs
  end

  it "gives the proc parameter the arguments the body calls it with" do
    target = write("app/store.rb", store_source)
    write("sig/generated/store.rbs", <<~RBS)
      class Store
        def initialize: () ?{ (*untyped) -> untyped } -> void

        private

        def install: ((^(*untyped) -> untyped)? fallback) -> untyped
      end
    RBS

    expect(generate(target)).to include("def install: ((^(self, Time) -> untyped)? fallback)")
  end

  it "gives the block the parameters of the proc it is handed to" do
    target = write("app/store.rb", store_source)
    write("sig/generated/store.rbs", <<~RBS)
      class Store
        def initialize: () ?{ (*untyped) -> untyped } -> void

        private

        def install: ((^(self, ::Time) -> untyped)? fallback) -> untyped
      end
    RBS

    expect(generate(target)).to include("def initialize: () ?{ (self, Time) -> untyped } -> void")
  end

  it "leaves a parameter the call sites did not type as a proc" do
    target = write("app/runner.rb", <<~RUBY)
      class Runner
        def run(callable)
          callable.call(1)
        end
      end
    RUBY

    rbs = RbsInfer::Analyzer.new(target_class: "Runner", target_file: target, source_files: [target]).generate_rbs

    expect(rbs).to include("def run: (untyped callable)")
  end
end
