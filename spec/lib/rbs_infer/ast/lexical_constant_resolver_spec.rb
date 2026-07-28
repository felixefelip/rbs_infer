# frozen_string_literal: true

require "spec_helper"

# felixefelip/rbs_infer#129. The ORDER is the whole contract: three components had
# each hand-rolled their own walk, and one of them (RbsTypeLookup's step 2c) peeled
# segments off the wrong end, generating candidates Ruby would never try while
# skipping ones it would.
RSpec.describe RbsInfer::AST::LexicalConstantResolver do
  describe ".candidates" do
    it "walks the enclosing scopes from the inside out" do
      expect(described_class.candidates(name: "Foo", enclosing: "A::B"))
        .to eq(["A::B::Foo", "A::Foo", "Foo"])
    end

    it "yields only the name at top level" do
      expect(described_class.candidates(name: "Foo", enclosing: nil)).to eq(["Foo"])
      expect(described_class.candidates(name: "Foo", enclosing: "")).to eq(["Foo"])
    end

    it "skips the walk for an absolute reference" do
      # `::Foo` inside `A::B` is the top-level constant, full stop — Ruby does not
      # consider `A::B::Foo` at all, so neither may we.
      expect(described_class.candidates(name: "::Foo", enclosing: "A::B")).to eq(["Foo"])
    end

    it "resolves the first segment of a qualified name lexically" do
      expect(described_class.candidates(name: "Foo::Bar", enclosing: "A"))
        .to eq(["A::Foo::Bar", "Foo::Bar"])
    end

    it "returns nothing for an absent name" do
      expect(described_class.candidates(name: nil, enclosing: "A")).to eq([])
      expect(described_class.candidates(name: "", enclosing: "A")).to eq([])
    end
  end

  describe ".candidates_for" do
    it "drops the joined prefix from the inside out" do
      # NOT `B::Foo` — that is what the front-peeling version produced, and it is
      # not a candidate under Ruby's rule.
      expect(described_class.candidates_for("A::B::Foo")).to eq(["A::B::Foo", "A::Foo", "Foo"])
    end

    it "leaves a bare name alone" do
      expect(described_class.candidates_for("Foo")).to eq(["Foo"])
    end
  end

  describe ".resolve" do
    it "takes the innermost candidate the oracle accepts" do
      known = ["A::Foo", "Foo"].to_set

      expect(described_class.resolve(name: "Foo", enclosing: "A::B") { |c| known.include?(c) })
        .to eq("A::Foo")
    end

    it "is nil when no candidate exists, so the caller can keep the written name" do
      expect(described_class.resolve(name: "Foo", enclosing: "A") { false }).to be_nil
    end
  end
end
