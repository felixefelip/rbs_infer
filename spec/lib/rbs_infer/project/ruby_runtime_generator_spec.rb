# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/ruby_runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::RubyRuntimeGenerator do
  def build_in(dir) = described_class.new(app_dir: dir).build

  it "emits `Module#include`, with the call it makes inside it" do
    Dir.mktmpdir do |dir|
      files = build_in(dir)

      expect(files.map(&:filename)).to eq(["module.rb"])
      expect(files.first.source).to include(
        "class Module\n",
        "  def include(*modules)\n" \
        "    modules.each { |mod| mod.included(self) }\n" \
        "    self\n" \
        "  end\n" \
        "end\n"
      )
    end
  end

  # A plain `def include` redeclares core's `Module#include`, which RBS rejects with
  # `DuplicatedMethodDefinitionError` — and that aborts the whole run, not just this file.
  # The marker (#200) makes the emitted signature RBS's overloading form instead.
  it "marks the def as overloading so it adds to core's signature" do
    Dir.mktmpdir do |dir|
      expect(build_in(dir).first.source).to match(/# @rbs_infer \|\.\.\.\n\s+def include\(/)
    end
  end

  describe "#generate" do
    it "writes the sidecar" do
      Dir.mktmpdir do |dir|
        sidecar = described_class.new(app_dir: dir).generate

        expect(File.read(File.join(sidecar, "module.rb"))).to include("mod.included(self)")
      end
    end

    it "rewrites a stale sidecar" do
      Dir.mktmpdir do |dir|
        sidecar = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(sidecar)
        File.write(File.join(sidecar, "included_hook.rb"), "::Gone.included(::Gone)\n")

        described_class.new(app_dir: dir).generate

        expect(Dir.children(sidecar)).to eq(["module.rb"])
      end
    end
  end
end
