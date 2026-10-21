# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a method returning a proc whose own return is untyped" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def generate(target)
    RbsInfer::Analyzer.new(target_file: target, source_files: Dir["app/*.rb"]).generate_rbs
  end

  def scoped = <<~RUBY
    class Scoped
      def scope
        ->(object) { object.anything }
      end
    end
  RUBY

  it "keeps the proc one level deep when its previous signature is read back" do
    target = write("app/scoped.rb", scoped)
    first = generate(target)
    expect(first).to include("def scope: () -> ^(untyped) -> untyped")

    write("sig/generated/scoped.rbs", first)
    RbsInfer::Signatures::RbsTypeLookup.reset!

    expect(generate(target)).to eq(first)
  end
end
