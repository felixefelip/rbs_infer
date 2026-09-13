# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rbs_infer"
require "rbs_infer/project/string_eval_sidecar"

RSpec.describe RbsInfer::Project::StringEvalSidecar do
  def with_sidecar(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, described_class::PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content) if content

      yield described_class.load(dir), dir
    end
  end

  it "reads what a call site writes" do
    with_sidecar(<<~YAML) do |sidecar|
      ---
      version: 1
      call_sites:
        app/models/article.rb:7:2:
        - "def content; end"
    YAML
      expect(sidecar.sources_for(path: "app/models/article.rb", line: 7, column: 2))
        .to eq(["def content; end"])
    end
  end

  it "is empty when the project has no sidecar" do
    with_sidecar(nil) do |sidecar|
      expect(sidecar).not_to be_any
      expect(sidecar.sources_for(path: "app/models/article.rb", line: 7, column: 2)).to be_nil
    end
  end

  it "resolves an absolute path against the project" do
    with_sidecar(<<~YAML) do |sidecar, dir|
      ---
      version: 1
      call_sites:
        app/models/article.rb:7:2:
        - "def content; end"
    YAML
      absolute = File.join(dir, "app/models/article.rb")

      expect(sidecar.sources_for(path: absolute, line: 7, column: 2)).to eq(["def content; end"])
    end
  end

  # A hole is what the checker writes for a chunk whose value the call site does
  # not fix. It declines the call site rather than handing back the rest.
  it "declines a call site whose list holds a hole" do
    with_sidecar(<<~YAML) do |sidecar|
      ---
      version: 1
      call_sites:
        app/models/article.rb:7:2:
        - "def content; end"
        -
    YAML
      expect(sidecar.sources_for(path: "app/models/article.rb", line: 7, column: 2)).to be_nil
    end
  end

  it "ignores a sidecar written by a version it does not know" do
    with_sidecar(<<~YAML) do |sidecar|
      ---
      version: 2
      call_sites:
        app/models/article.rb:7:2:
        - "def content; end"
    YAML
      expect(sidecar).not_to be_any
    end
  end

  it "ignores a sidecar it cannot parse" do
    with_sidecar("--- {[") do |sidecar|
      expect(sidecar).not_to be_any
    end
  end
end
