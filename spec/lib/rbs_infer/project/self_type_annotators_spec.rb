# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::SelfTypeAnnotators do
  # A fake annotator that records the source it was asked to inspect and emits
  # a fixed entry, so we can assert detection-source vs injection-target without
  # depending on a real Rails extension.
  def fake_annotator(entries:, seen:)
    Module.new do
      define_singleton_method(:self_type_entries) do |path:, module_name:, source:|
        seen << { path: path, module_name: module_name, source: source }
        entries
      end
    end
  end

  around do |example|
    saved = described_class.annotators
    saved.each { |a| described_class.unregister(a) }
    example.run
    described_class.annotators.each { |a| described_class.unregister(a) }
    saved.each { |a| described_class.register(a) }
  end

  let(:target_source) { "module Foo\n  module Bar\n  end\nend\n" }
  let(:original_source) { "module Foo\n  bar do\n  end\nend\n" }

  describe ".register / .unregister" do
    it "is idempotent and reversible" do
      a = Module.new
      described_class.register(a)
      described_class.register(a)
      expect(described_class.annotators).to eq([a])

      described_class.unregister(a)
      expect(described_class.annotators).to eq([])
    end
  end

  describe ".apply" do
    it "injects each registered annotator's entry into the target source" do
      seen = []
      described_class.register(
        fake_annotator(seen: seen, entries: [{ "anchor" => "Bar", "annotations" => ["# @type self: singleton(::Foo)"] }])
      )

      result = described_class.apply(
        target_source, detect_source: original_source, path: "app/models/foo.rb", module_name: "Foo"
      )

      expect(result).to include("# @type self: singleton(::Foo)")
    end

    it "detects from detect_source but injects into target_source" do
      seen = []
      described_class.register(fake_annotator(seen: seen, entries: []))

      described_class.apply(
        target_source, detect_source: original_source, path: "app/models/foo.rb", module_name: "Foo"
      )

      expect(seen.first[:source]).to eq(original_source)
      expect(seen.first[:module_name]).to eq("Foo")
    end

    it "returns the target source unchanged when no annotators are registered" do
      result = described_class.apply(
        target_source, detect_source: original_source, path: "x.rb", module_name: "Foo"
      )
      expect(result).to eq(target_source)
    end

    it "is a no-op (and never calls annotators) when module_name is blank" do
      seen = []
      described_class.register(fake_annotator(seen: seen, entries: [{ "anchor" => "Bar", "annotations" => ["# @type self: X"] }]))

      expect(described_class.apply(target_source, detect_source: original_source, path: "x.rb", module_name: nil)).to eq(target_source)
      expect(described_class.apply(target_source, detect_source: original_source, path: "x.rb", module_name: "")).to eq(target_source)
      expect(seen).to be_empty
    end
  end

  describe "default registrations" do
    it "registers the Rails self-type annotators at require time" do
      # Outside the around hook's teardown these are the real registrations.
      expect(RbsInfer::Extensions::Rails::ModuleSelfTypeAnnotator).to respond_to(:self_type_entries)
      expect(RbsInfer::Extensions::Rails::ClassMethodsImplements).to respond_to(:self_type_entries)
    end
  end
end
