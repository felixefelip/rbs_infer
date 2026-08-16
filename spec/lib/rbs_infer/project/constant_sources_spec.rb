# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Project::ConstantSources do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def write(path, source)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, source)
    path
  end

  def sources_over(*files)
    described_class.new(
      source_index: RbsInfer::Project::SourceIndex.new(files),
      file_index: RbsInfer::Project::FileIndex.new(files),
      parse_cache: RbsInfer::Project::ParseCache.new
    )
  end

  it "finds a class declared in the file its name implies" do
    files = [write("app/models/widget.rb", "class Widget\nend\n")]

    expect(sources_over(*files).parsed_for("Widget").map(&:source)).to eq(["class Widget\nend\n"])
  end

  # The case the path convention cannot answer: a core class is reopened
  # wherever the project felt like putting the patch.
  it "finds a core reopening in a file the name does not point at" do
    files = [write("lib/patches/core_extensions.rb", "class Module\n  def banana(*mods) = mods\nend\n")]

    expect(sources_over(*files).parsed_for("Module").map(&:source)).to include(/class Module/)
  end

  it "does not return a file that only mentions the name" do
    files = [write("app/models/widget.rb", "class Widget\n  # See Module for why\n  BANANA = Module\nend\n")]

    expect(sources_over(*files).parsed_for("Module")).to be_empty
  end

  it "matches a nested declaration by its qualified name" do
    files = [write("app/models/wrap/inner.rb", "module Wrap\n  module Inner\n  end\nend\n")]

    expect(sources_over(*files).parsed_for("Wrap::Inner")).not_to be_empty
    expect(sources_over(*files).parsed_for("Inner")).to be_empty
  end

  it "returns every file that reopens the constant" do
    files = [write("lib/a.rb", "class Module\n  def one = 1\nend\n"),
             write("lib/b.rb", "class Module\n  def two = 2\nend\n")]

    expect(sources_over(*files).parsed_for("Module").size).to eq(2)
  end

  it "answers nothing for a constant the project does not declare" do
    files = [write("app/models/widget.rb", "class Widget\nend\n")]

    expect(sources_over(*files).parsed_for("Absent")).to be_empty
  end

  describe "NONE" do
    it "answers nothing, so a caller with no project says so explicitly" do
      expect(described_class::NONE.parsed_for("Module")).to eq([])
    end
  end
end
