require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::NodeTypeInferrer do
  def infer_hash(source, known_types: {}, context_class: nil)
    result = Prism.parse(source)
    hash_node = find_hash_node(result.value)
    described_class.infer_hash_type(hash_node, known_types: known_types, context_class: context_class)
  end

  def find_hash_node(node)
    return node if node.is_a?(Prism::HashNode)
    node.compact_child_nodes.each do |child|
      found = find_hash_node(child)
      return found if found
    end
    nil
  end

  describe ".infer_hash_type" do
    it "returns record type for all-Symbol keys" do
      expect(infer_hash("{ foo: 'bar', baz: 42 }")).to eq("{ foo: String, baz: Integer }")
    end

    it "returns record type with various literal value types" do
      expect(infer_hash("{ s: 'x', i: 1, f: 1.5, sym: :a, b: true, n: nil }")).to eq(
        "{ s: String, i: Integer, f: Float, sym: Symbol, b: bool, n: nil }"
      )
    end

    it "returns nested record type for nested hashes" do
      expect(infer_hash("{ a: 1, nested: { b: 2, c: 3 } }")).to eq(
        "{ a: Integer, nested: { b: Integer, c: Integer } }"
      )
    end

    it "returns record type with Klass.new values" do
      expect(infer_hash("{ comment: Comment.new }")).to eq("{ comment: Comment }")
    end

    it "returns record type with constant values" do
      expect(infer_hash("{ klass: MyModule::MyClass }")).to eq("{ klass: MyModule::MyClass }")
    end

    it "uses untyped for complex expressions in values" do
      expect(infer_hash("{ result: some_method(1, 2) }")).to eq("{ result: untyped }")
    end

    it "falls back to Hash[K, untyped] for mixed key types" do
      expect(infer_hash("{ 'a' => 1, 'b' => 2 }")).to eq("Hash[String, untyped]")
    end

    it "falls back to Hash[untyped, untyped] for mixed Symbol and String keys" do
      expect(infer_hash("{ foo: 1, 'bar' => 2 }")).to eq("Hash[untyped, untyped]")
    end

    it "falls back to Hash[Symbol, untyped] for splat" do
      expect(infer_hash("{ foo: 1, **opts }")).to eq("Hash[Symbol, untyped]")
    end

    it "returns Hash[untyped, untyped] for empty hash" do
      expect(infer_hash("{}")).to eq("Hash[untyped, untyped]")
    end

    it "handles regex values" do
      expect(infer_hash("{ pattern: /abc/ }")).to eq("{ pattern: Regexp }")
    end

    it "handles array values" do
      expect(infer_hash("{ items: [1, 2, 3] }")).to eq("{ items: Array[untyped] }")
    end

    context "with known_types context" do
      it "resolves local variable reads to known types" do
        expect(infer_hash("{ name: user_name }", known_types: { "user_name" => "String" })).to eq(
          "{ name: String }"
        )
      end

      it "resolves receiverless method calls to known types" do
        expect(infer_hash("{ addr: from_address }", known_types: { "from_address" => "String" })).to eq(
          "{ addr: String }"
        )
      end

      it "falls back to untyped when known_types has no entry" do
        expect(infer_hash("{ val: unknown_var }", known_types: { "other" => "String" })).to eq(
          "{ val: untyped }"
        )
      end

      it "mixes literal and context-resolved types" do
        known = { "from_address" => "String" }
        expect(infer_hash("{ from: from_address, count: 42 }", known_types: known)).to eq(
          "{ from: String, count: Integer }"
        )
      end
    end
  end
end
