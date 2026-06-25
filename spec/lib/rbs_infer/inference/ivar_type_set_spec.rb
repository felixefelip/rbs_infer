require "spec_helper"
require "rbs_infer/inference/ivar_type_set"

RSpec.describe RbsInfer::Inference::IvarTypeSet do
  subject(:set) { described_class.new }

  describe "#add and #emit" do
    it "returns nil for empty set without force_nilable" do
      expect(set.emit).to be_nil
    end

    it "returns 'nil' for empty set with force_nilable" do
      expect(set.emit(force_nilable: true)).to eq("nil")
    end

    it "emits a single type unchanged" do
      set.add("String")
      expect(set.emit).to eq("String")
    end

    it "appends ? to single type when force_nilable" do
      set.add("String")
      expect(set.emit(force_nilable: true)).to eq("String?")
    end

    it "unwraps T? into T plus implicit nilability" do
      set.add("String?")
      expect(set.emit).to eq("String?")
    end

    it "treats `nil` literal as nilability flag, not a type" do
      set.add("String")
      set.add("nil")
      expect(set.emit).to eq("String?")
    end

    it "dedupes textually-equal types" do
      set.add("Comment")
      set.add("Comment")
      expect(set.emit).to eq("Comment")
    end

    it "dedupes whitespace-insensitive" do
      set.add("(A & B)")
      set.add("( A  &  B )")
      expect(set.emit).to eq("(A & B)")
    end

    it "emits a union for multiple distinct types" do
      set.add("A")
      set.add("B")
      expect(set.emit).to eq("A | B")
    end

    it "wraps multi-type union in (...)? when nilable" do
      set.add("A")
      set.add("B")
      expect(set.emit(force_nilable: true)).to eq("(A | B)?")
    end

    it "preserves insertion order in the union" do
      set.add("Z")
      set.add("A")
      expect(set.emit).to eq("Z | A")
    end

    it "ignores untyped and bot" do
      set.add("untyped")
      set.add("bot")
      set.add("Foo")
      expect(set.emit).to eq("Foo")
    end

    it "ignores blank, whitespace-only, and nil inputs" do
      set.add(nil)
      set.add("")
      set.add("   ")
      set.add("Foo")
      expect(set.emit).to eq("Foo")
    end

    it "does NOT semantically simplify (A & B) | A" do
      set.add("(A & B)")
      set.add("A")
      # Per the issue: keep the syntactic union; steep#16 dispatches on it.
      expect(set.emit).to eq("(A & B) | A")
    end

    it "combines T? input with another T into single nilable union" do
      set.add("A?")
      set.add("B")
      expect(set.emit).to eq("(A | B)?")
    end
  end

  describe "#empty?" do
    it "is true on a fresh set" do
      expect(set).to be_empty
    end

    it "is false once a type is added" do
      set.add("Foo")
      expect(set).not_to be_empty
    end

    it "is false when only nil literal was added" do
      set.add("nil")
      expect(set).not_to be_empty
    end

    it "stays empty when only ignorable inputs are added" do
      set.add("untyped")
      set.add("bot")
      set.add("")
      expect(set).to be_empty
    end
  end
end
