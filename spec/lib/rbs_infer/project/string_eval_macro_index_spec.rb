# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/string_eval_macro_index"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::StringEvalMacroIndex do
  def in_files(files)
    Dir.mktmpdir do |dir|
      paths = files.map do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end
      yield described_class.new(paths)
    end
  end

  SLOT = <<~'RUBY'
    module Slots
      def slot(name)
        class_eval "def #{name}; @#{name}; end"
      end
    end
  RUBY

  it "finds a macro by the name a call site spells" do
    in_files("slots.rb" => SLOT) do |index|
      expect(index[:slot]).not_to be_nil
      expect(index).to be_any
    end
  end

  # A receiverless call names a method by its name alone, and which one it
  # reaches is a question of the ancestor chain — which for a gem's macro lives
  # in RBS, not in the Ruby this index reads. One candidate is an answer; two is
  # a guess, and a guess writes methods onto a class that does not have them.
  it "drops a name two files declare" do
    other = SLOT.sub("module Slots", "module OtherSlots")

    in_files("slots.rb" => SLOT, "other.rb" => other) do |index|
      expect(index[:slot]).to be_nil
    end
  end

  it "does not resurrect a dropped name from a third file" do
    second = SLOT.sub("module Slots", "module OtherSlots")
    third = SLOT.sub("module Slots", "module ThirdSlots")

    in_files("a.rb" => SLOT, "b.rb" => second, "c.rb" => third) do |index|
      expect(index[:slot]).to be_nil
    end
  end

  it "ignores a method that evals no string" do
    in_files("plain.rb" => "module Slots\n  def slot(name)\n    name\n  end\nend\n") do |index|
      expect(index[:slot]).to be_nil
      expect(index).not_to be_any
    end
  end

  it "survives a file it cannot parse" do
    in_files("broken.rb" => "class Oops\n  class_eval \"def\n", "slots.rb" => SLOT) do |index|
      expect(index[:slot]).not_to be_nil
    end
  end

  # The gate that keeps a project without the idiom from paying for the walk.
  it "answers nothing for a corpus that writes no eval" do
    in_files("plain.rb" => "class Widget\n  def size; 1; end\nend\n") do |index|
      expect(index).not_to be_any
    end
  end

  it "has a null answer for a caller with no project" do
    expect(described_class.none).not_to be_any
    expect(described_class.none[:slot]).to be_nil
  end
end
