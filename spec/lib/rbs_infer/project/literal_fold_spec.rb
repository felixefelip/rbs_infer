# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/literal_fold"

RSpec.describe RbsInfer::Project::LiteralFold do
  # A method, not a constant: a constant written in a `describe` block lands on
  # Object and collides with any other spec file that names it.
  def unknown
    described_class::UNKNOWN
  end

  # Bindings map a name to the NODE it holds, which is what a call site hands a
  # macro. Parsed here so the spec states the Ruby rather than the AST.
  def node_for(source)
    Prism.parse(source).value.statements.body.first
  end

  def fold(source, **bindings)
    described_class.fold(node_for(source), bindings.transform_values { |value| node_for(value) })
  end

  describe "the domain" do
    it "folds the literals a macro is called with" do
      expect(fold('"content"')).to eq("content")
      expect(fold(":content")).to eq(:content)
      expect(fold("true")).to be(true)
      expect(fold("false")).to be(false)
      expect(fold("nil")).to be_nil
    end

    it "folds an interpolation whose parts it can reach" do
      expect(fold('"rich_text_#{name}"', name: ":content")).to eq("rich_text_content")
    end

    it "reads a name only from the bindings it was given" do
      expect(fold("name", name: ":content")).to eq(:content)
      expect(fold("name")).to be(unknown)
    end
  end

  # The property the module exists for. Every other example is a consequence.
  describe "the unknown" do
    it "refuses what it cannot reach rather than answering" do
      expect(fold("SOME_CONST")).to be(unknown)
      expect(fold("options[:fancy]")).to be(unknown)
      expect(fold("name.to_s.upcase", name: ":content")).to be(unknown)
      expect(fold("@configured")).to be(unknown)
    end

    # The distinction the two old readers collapsed: a name nobody bound is not
    # a name bound to nil, and only the second is falsy.
    it "does not read an unbound name as nil" do
      expect(described_class.truthy(fold("writable"))).to be(unknown)
      expect(described_class.truthy(fold("writable", writable: "nil"))).to be(false)
    end

    it "propagates through every operator it folds" do
      expect(fold("!writable")).to be(unknown)
      expect(fold("writable && true")).to be(unknown)
      expect(fold('"def #{missing}"')).to be(unknown)
    end

    # A sentinel a call site can spell is a sentinel that lies. `slot :unknown`
    # binds a parameter to a symbol, and the symbol must not read as a refusal.
    it "is not a value the domain can also hold" do
      expect(fold(":unknown")).to eq(:unknown)
      expect(fold(":unknown")).not_to be(unknown)
      expect(described_class).not_to be_unknown(fold(":unknown"))
    end
  end

  describe "the conditions a macro branches on" do
    it "negates what it folded" do
      expect(fold("!writable", writable: "false")).to be(true)
      expect(fold("!writable", writable: "true")).to be(false)
    end

    it "compares two folded values" do
      expect(fold("kind == :rw", kind: ":rw")).to be(true)
      expect(fold("kind != :rw", kind: ":ro")).to be(true)
      # A symbol and a string are not equal, the way Ruby has it — even though
      # both interpolate to the same text.
      expect(fold('kind == "rw"', kind: ":rw")).to be(false)
    end

    it "short-circuits on the side that decides" do
      expect(fold("writable && SOME_CONST", writable: "false")).to be(false)
      expect(fold("writable || SOME_CONST", writable: "true")).to be(true)
      expect(fold("writable && SOME_CONST", writable: "true")).to be(unknown)
    end

    it "takes the branch of a conditional expression" do
      expect(fold("encrypted ? :enc : :plain", encrypted: "true")).to eq(:enc)
      expect(fold("encrypted ? :enc : :plain", encrypted: "false")).to eq(:plain)
    end
  end

  describe "the text a value interpolates to" do
    it "follows Ruby for the values it holds" do
      expect(described_class.to_text(:content)).to eq("content")
      expect(described_class.to_text("content")).to eq("content")
      expect(described_class.to_text(true)).to eq("true")
    end

    # `nil` interpolates to "" in Ruby, which turns `def #{name}` into `def ` —
    # a SyntaxError at `class_eval` time, not a definition.
    it "refuses nil rather than writing an empty name" do
      expect(described_class.to_text(nil)).to be(unknown)
      expect(described_class.to_text(unknown)).to be(unknown)
    end
  end
end
