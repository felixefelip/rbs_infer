# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
# The macro is sliced from the installed gem, so the gem has to be loaded for
# there to be anything to slice.
require "action_text"
require "rbs_infer/extensions/rails/action_text/runtime_generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Rails::ActionText::RuntimeGenerator do
  def files
    described_class.new(app_dir: ".").build
  end

  def source
    files.first[:source]
  end

  # The whole extension: put the gem's macro where the pipeline can read it.
  # Rendering it per call site belongs to `Project::StringEvalMacroExpander`,
  # which is covered by its own spec and knows no framework.
  describe "the file it writes" do
    it "emits one file, holding the macro's own source" do
      expect(files.map { |file| file[:filename] }).to eq(["attribute.rb"])
      expect(source).to include("def has_rich_text(name")
      expect(source).to include("class_eval")
    end

    it "nests the macro in the module it was written in" do
      expect(source).to include("module ActionText\n  module Attribute\n    module ClassMethods\n")
    end

    # Verbatim, so a Rails that rewrites the macro lands here on its own. The
    # interpolations in particular have to survive — they are what the expander
    # binds to a call site's arguments.
    it "keeps the interpolations rather than resolving them" do
      expect(source).to include('def #{name}')
      expect(source).to include('rich_text_#{name} || build_rich_text_#{name}')
    end

    # `store_if_blank:` selects a different writer. The generator does not know
    # that; it transcribes the branch and the expander reads it.
    it "keeps the branch instead of choosing one" do
      expect(source).to include("if store_if_blank")
      expect(source).to include("mark_for_destruction")
    end

    it "keeps the has_one and the scopes the macro also declares" do
      expect(source).to include("has_one :\"rich_text_\#{name}\"")
      expect(source).to include("scope :\"with_rich_text_\#{name}\"")
    end
  end

  describe "what it does not say" do
    # The rule the Devise, AR-runtime and Concern transcriptions all follow.
    # On the annotation SYNTAX, not on tokens: `-> { where(name: name) }` is a
    # lambda the macro really writes, and the `"ActionText::RichText"` further
    # down is the `class_name:` string it passes to `has_one` — the gem's own
    # code, not a signature.
    it "states no type" do
      expect(source).not_to match(/^\s*#:/)
      expect(source).not_to include("@type")
      expect(source).not_to match(/@rbs (?!_infer)/)
    end

    # `# @rbs_infer |...` is precedence, not a signature: gem_rbs_collection
    # already declares `has_rich_text`, and a second PLAIN declaration is a
    # DuplicatedMethodDefinitionError that poisons the whole environment.
    it "marks the def for the overloading form" do
      expect(source).to include("# @rbs_infer |...\n      def has_rich_text")
    end
  end

  describe "#generate" do
    it "writes the file into the sidecar dir" do
      Dir.mktmpdir do |dir|
        path = described_class.new(app_dir: dir).generate

        expect(path).to eq(File.join(dir, described_class::SIDECAR_DIR))
        expect(File.read(File.join(path, "attribute.rb"))).to include("def has_rich_text(name")
      end
    end

    # `sig/**/*.rb` is how the analyzer and the Steep fork pick this up, and
    # `**` skips hidden directories — a dot-prefixed dir would be invisible.
    it "writes to a directory Steep's source glob can see" do
      expect(described_class::SIDECAR_DIR).to eq("sig/generated/steep_actiontext_runtime")
      expect(described_class::SIDECAR_DIR).not_to include("/.")
    end

    # It describes the FRAMEWORK, not the app, so it does not wait for a model
    # to declare the macro — the first model to write one would otherwise be the
    # thing that made ActionText appear.
    it "writes it for an app with no model at all" do
      Dir.mktmpdir do |dir|
        expect(described_class.new(app_dir: dir).build).not_to be_empty
      end
    end
  end
end
