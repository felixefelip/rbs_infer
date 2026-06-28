require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::NodeTypeInferrer do
  def infer_hash(source, known_types: {}, context_class: nil, constant_resolver: fake_constant_resolver)
    result = Prism.parse(source)
    hash_node = find_hash_node(result.value)
    described_class.infer_hash_type(hash_node, known_types: known_types, context_class: context_class, constant_resolver: constant_resolver)
  end

  def find_hash_node(node)
    return node if node.is_a?(Prism::HashNode)
    node.compact_child_nodes.each do |child|
      found = find_hash_node(child)
      return found if found
    end
    nil
  end

  describe ".infer_literal_node_type" do
    def infer_literal(source, constant_resolver: fake_constant_resolver)
      node = Prism.parse(source).value.statements.body.first
      described_class.infer_literal_node_type(node, constant_resolver: constant_resolver)
    end

    # The single source of truth shared by every value typer (#58). Each literal
    # kind must map identically regardless of caller — this is what the per-class
    # copies used to drift on (e.g. some missed Array/Hash/InterpolatedSymbol).
    it "maps every unambiguous literal node to its RBS type" do
      expect(infer_literal('"x"')).to eq("String")
      expect(infer_literal('"a#{b}c"')).to eq("String")          # InterpolatedString
      expect(infer_literal("1")).to eq("Integer")
      expect(infer_literal("1.5")).to eq("Float")
      expect(infer_literal(":a")).to eq("Symbol")
      expect(infer_literal(':"a#{b}"')).to eq("Symbol")          # InterpolatedSymbol
      expect(infer_literal("true")).to eq("bool")
      expect(infer_literal("false")).to eq("bool")
      expect(infer_literal("nil")).to eq("nil")
      expect(infer_literal("[1, 2]")).to eq("Array[untyped]")
      expect(infer_literal("{ a: 1 }")).to eq("{ a: Integer }")
      expect(infer_literal("/abc/")).to eq("Regexp")
      expect(infer_literal('/a#{b}/')).to eq("Regexp")           # InterpolatedRegexp
    end

    it "returns nil for context-dependent nodes (caller layers its own resolution)" do
      expect(infer_literal("foo")).to be_nil                     # CallNode / receiverless
      expect(infer_literal("@x")).to be_nil                      # InstanceVariableRead
      expect(infer_literal("self")).to be_nil                    # SelfNode
      expect(infer_literal("SOME_CONST")).to be_nil              # ConstantRead
    end
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

    it "types a constant value via the resolver (its VALUE type, not the bare name) (#56)" do
      resolver = fake_constant_resolver("MyModule::MyClass" => "Integer")
      expect(infer_hash("{ klass: MyModule::MyClass }", constant_resolver: resolver)).to eq("{ klass: Integer }")
    end

    it "uses untyped for a constant value the resolver can't classify (never the bare name) (#56)" do
      expect(infer_hash("{ klass: MyModule::MyClass }")).to eq("{ klass: untyped }")
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
