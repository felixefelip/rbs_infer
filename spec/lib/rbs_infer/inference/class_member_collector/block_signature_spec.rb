require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ClassMemberCollector::BlockSignature do
  # The rule reads the BODY, so each example is a whole method.
  def signature_for(source)
    def_node = Prism.parse(source).value.statements.body.first
    described_class.new(def_node.parameters, body: def_node.body).call
  end

  describe "required" do
    it "is required when the body calls the block parameter" do
      expect(signature_for("def m(&block); block.call(1); end")).to eq("{ (untyped) -> untyped }")
    end

    it "is required when the body yields" do
      expect(signature_for("def m; yield 1; end")).to eq("{ (untyped) -> untyped }")
    end

    it "covers `block.()`, which Prism spells as a `call`" do
      expect(signature_for("def m(&block); block.(1); end")).to eq("{ (untyped) -> untyped }")
    end
  end

  describe "optional" do
    # A guard is precisely what makes `?{ … }` the right answer, so its presence
    # is what keeps the `?`. Each of these is a way of asking "is there a block".
    it "is optional when guarded by `if block`" do
      expect(signature_for("def m(&block); block.call(1) if block; end")).to eq("?{ (untyped) -> untyped }")
    end

    it "is optional when guarded by `block_given?`" do
      expect(signature_for("def m; yield 1 if block_given?; end")).to eq("?{ (untyped) -> untyped }")
    end

    it "is optional when called through `&.`" do
      expect(signature_for("def m(&block); block&.call(1); end")).to eq("?{ (untyped) -> untyped }")
    end

    it "is optional when the body tests `block.nil?`" do
      expect(signature_for("def m(&block); block.call(1) unless block.nil?; end")).to eq("?{ (untyped) -> untyped }")
    end

    # Passing a nil block along is legal Ruby, and a helper that forwards to
    # `tag.section` or `items.each` is called without one all the time.
    it "is optional when the body only FORWARDS the block" do
      expect(signature_for("def m(&block); other(&block); end")).to eq("?{ (*untyped) -> untyped }")
    end
  end

  describe "arity" do
    it "takes the arity from the use site" do
      expect(signature_for("def m(&block); block.call(1, 2); end")).to eq("{ (untyped, untyped) -> untyped }")
    end

    it "takes it from a yield too" do
      expect(signature_for("def m; yield 1, 2, 3; end")).to eq("{ (untyped, untyped, untyped) -> untyped }")
    end

    it "falls back to `*untyped` when the use sites disagree" do
      expect(signature_for("def m(&block); block.call(1); block.call(1, 2); end"))
        .to eq("{ (*untyped) -> untyped }")
    end

    # A guarded block is just as callable, so the body decides its arity too —
    # this read `?{ (untyped) -> untyped }` whatever the body did.
    it "reads the body for an OPTIONAL block as well" do
      expect(signature_for("def m(&block); block.call(1, 2) if block; end"))
        .to eq("?{ (untyped, untyped) -> untyped }")
    end
  end

  # The types at those sites are the checker's answer, so this only records
  # where to look — line and CHARACTER column, which is what a Parser-based
  # lookup is keyed by.
  describe "#arg_positions" do
    def positions_for(source)
      def_node = Prism.parse(source).value.statements.body.first
      described_class.new(def_node.parameters, body: def_node.body).arg_positions
    end

    it "points at each argument the body passes to the block" do
      expect(positions_for("def m(&block)\n  block.call(x, y)\nend")).to eq([[[2, 13]], [[2, 16]]])
    end

    it "collects every site for the same parameter, so they can be unioned" do
      expect(positions_for("def m\n  yield 1\n  yield 2\nend")).to eq([[[2, 8], [3, 8]]])
    end

    it "has nothing to say when the arity itself is unknown" do
      expect(positions_for("def m(&block); other(&block); end")).to eq([])
    end
  end

  # Forwarding proves nothing by itself, so the question is left open for the
  # callee to answer — but only when the body says nothing else at all.
  describe "#open_forward?" do
    def open_forward?(source)
      def_node = Prism.parse(source).value.statements.body.first
      described_class.new(def_node.parameters, body: def_node.body).open_forward?
    end

    it "is open when the body does nothing but forward" do
      expect(open_forward?("def m(&block); other(&block); end")).to be(true)
    end

    it "is closed by a guard, which says optional whatever the callee wants" do
      expect(open_forward?("def m(&block); other(&block) if block; end")).to be(false)
    end

    it "is closed by the body calling the block itself — better evidence" do
      expect(open_forward?("def m(&block); block.call(1); other(&block); end")).to be(false)
    end

    it "is closed when nothing is forwarded" do
      expect(open_forward?("def m(&block); other(1); end")).to be(false)
    end

    # `&:upcase` builds a proc on the spot; it is not this method's block.
    it "is closed when the method has no block parameter" do
      expect(open_forward?("def m(items); items.map(&:upcase); end")).to be(false)
    end
  end

  it "is absent when the method neither takes nor yields a block" do
    expect(signature_for("def m(a, b); a + b; end")).to be_nil
  end

  it "reads the body, not the parameter list: no body means no answer to give" do
    def_node = Prism.parse("def m(&block); end").value.statements.body.first
    expect(described_class.new(def_node.parameters, body: nil).call).to eq("?{ (*untyped) -> untyped }")
  end
end
