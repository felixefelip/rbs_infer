# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/active_support/runtime_generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Rails::ActiveSupport::RuntimeGenerator do
  def files
    described_class.new(app_dir: ".").build
  end

  def source
    files.first[:source]
  end

  # The whole extension: put the gem's macro where the pipeline can read it.
  # What it writes at each call site is folded by the checker and placed by
  # `Project::StringEvalMacroExpander`, which knows no framework.
  describe "the file it writes" do
    it "emits one file, holding `delegate` and the writer it hands its arguments to" do
      expect(files.map { |file| file[:filename] }).to eq(["delegation.rb"])
      expect(source).to include("def delegate(*methods, to: nil")
      expect(source).to include("def delegate_missing_to(target")
      expect(source).to include("def generate(owner, methods")
    end

    # `Module#delegate` is reopened on `Module`, where ActiveSupport writes it.
    it "reopens Module for the macros" do
      expect(source).to match(/^class Module\n  # @rbs_infer \|\.\.\.\n  def delegate\(/)
    end

    # The whole `Delegation` module, not just `generate`: `generate` reads
    # `RESERVED_METHOD_NAMES`, and a constant left out is one the checker
    # cannot fold — `to: :class` decides on it.
    it "keeps the writer's module whole, constants included" do
      expect(source).to include("module ActiveSupport\n  module Delegation")
      expect(source).to include("RESERVED_METHOD_NAMES = (RUBY_RESERVED_KEYWORDS")
      expect(source).to include("class << self")
    end

    # Verbatim, so an ActiveSupport that rewrites the generator lands here on
    # its own — the reflection branch in particular, which writes `to: :class`'s
    # parameter list.
    it "keeps the reflection branch rather than resolving it" do
      expect(source).to include("receiver_class.public_instance_method(method)")
      expect(source).to include("parameters.filter_map { |type, arg| arg if type == :req }")
      expect(source).to include('owner.module_eval(method_def.join(";"), file, line)')
    end
  end

  describe "what it does not say" do
    # The rule every transcription follows. The one annotation is `|...`,
    # which says the signature is the app's call sites', ADDED to the gem's —
    # not a type.
    it "states no type" do
      expect(source).not_to match(/^\s*#:/)
      expect(source).not_to include("@type")
      expect(source).not_to match(/@rbs (?!_infer)/)
    end

    it "puts each macro's signature ahead of the gem's `untyped` one" do
      expect(source.scan("# @rbs_infer |...").size).to eq(2)
    end
  end

  describe "#generate" do
    it "writes the file under the sidecar dir" do
      Dir.mktmpdir do |dir|
        path = described_class.new(app_dir: dir).generate

        expect(path).to eq(File.join(dir, described_class::SIDECAR_DIR))
        expect(File.read(File.join(path, "delegation.rb"))).to include("def delegate(")
      end
    end
  end
end
