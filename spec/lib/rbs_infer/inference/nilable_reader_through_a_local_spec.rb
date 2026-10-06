# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A call on a nilable reader has a value only on the branch that is not nil:
# the nil branch raises a `NoMethodError`, which is `bot`, and `T | bot` is
# `T`. That is how `user.name` is typed, and a local holding the reader, or a
# `rescue` that only raises, changes nothing about it.
RSpec.describe "a call on a nilable reader" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def generate(body)
    target = write("app/target.rb", "class Target\n  def user = (User.new if rand > 0.5)\n\n#{body.gsub(/^/, "  ")}end\n")
    RbsInfer::Analyzer.new(target_class: "Target", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs
  end

  before do
    write("app/user.rb", "class User\n  def name(title)\n    title\n  end\nend\n")
    write("sig/generated/user.rbs", "class User\n  def name: (String title) -> String\nend\n")
    write("sig/generated/target.rbs", "class Target\n  def user: () -> User?\nend\n")
  end

  it "is typed directly" do
    expect(generate("def label\n  user.name(\"Dr\")\nend\n")).to include("def label: () -> String")
  end

  # The local is the reader by the checker's own rule
  # (`Steep::Contracts::AliasResolver.local_aliases`, felixefelip/steep#203).
  it "is typed through a local holding the reader" do
    expect(generate("def label\n  u = user\n  u.name(\"Dr\")\nend\n")).to include("def label: () -> String")
    expect(generate("def label\n  _ = user\n  _.name(\"Dr\")\nend\n")).to include("def label: () -> String")
  end

  it "is not typed through a local that is not always the reader" do
    rbs = generate("def label\n  u = user\n  u = nil if rand > 0.5\n  u.name(\"Dr\")\nend\n")

    expect(rbs).not_to include("def label: () -> String")
  end

  # A clause that only raises adds no value.
  it "is typed through a rescue that only raises" do
    rbs = generate(<<~RUBY)
      def label
        user.name("Dr")
      rescue NoMethodError => e
        if e.name == :name
          raise ArgumentError
        else
          raise
        end
      end
    RUBY

    expect(rbs).to include("def label: () -> String")
  end

  it "leaves a rescue that can end with a value to the passes that read it" do
    rbs = generate("def label\n  user.name(\"Dr\")\nrescue NoMethodError\n  \"fallback\"\nend\n")

    expect(rbs).not_to include("def label: () -> String\n")
  end
end
