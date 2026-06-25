require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::ConstructorTypeInferrer do
  # RHS node of a `NAME = <expr>` statement.
  def rhs(code)
    Prism.parse(code).value.statements.body.first.value
  end

  def infer(code, target_class: "Color")
    described_class.new(target_class: target_class).infer(rhs(code))
  end

  describe "#infer" do
    it "resolves receiverless / self new to the target class" do
      expect(infer("X = new")).to eq("Color")
      expect(infer("X = self.new")).to eq("Color")
    end

    it "resolves Klass.new to the constant" do
      expect(infer("X = Widget.new")).to eq("Widget")
      expect(infer("X = Foo::Bar.new")).to eq("Foo::Bar")
    end

    it "passes the receiver's constructor type through freeze/dup & friends" do
      expect(infer("X = new.freeze")).to eq("Color")
      expect(infer("X = Widget.new.dup")).to eq("Widget")
      expect(infer("X = Widget.new.tap { |w| w }")).to eq("Widget")
    end

    it "wraps a block body's constructor type in Array for map/collect/flat_map" do
      expect(infer("X = [1, 2].map { |i| Widget.new(i) }")).to eq("Array[Widget]")
      expect(infer('X = { "a" => 1 }.collect { |k, v| new(k, v) }.freeze')).to eq("Array[Color]")
    end

    it "returns nil for non-constructor shapes (caller falls through)" do
      expect(infer("X = some_runtime_call")).to be_nil
      expect(infer('X = "literal"')).to be_nil
      expect(infer("X = [1, 2, 3]")).to be_nil
      expect(infer("X = self.class.new")).to be_nil # computed receiver
    end

    it "returns nil for the target class when it is nil" do
      expect(infer("X = new", target_class: nil)).to be_nil
    end
  end
end
