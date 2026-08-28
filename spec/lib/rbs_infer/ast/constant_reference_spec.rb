# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::ConstantReference do
  # The expression under test is the whole of each example, so the node to read
  # is the program's one statement.
  def node(source)
    Prism.parse(source).value.statements.body.first
  end

  describe ".named" do
    # A constant is syntax: which namespace it means is decided by the scope it
    # was WRITTEN in, which this module does not know — so the node travels back
    # for the caller to resolve.
    it "answers the node itself for a constant written as syntax" do
      written = node("Foo::Bar")

      expect(described_class.named(written)).to eq([written, false, nil])
    end

    it "answers the same for a bare constant" do
      written = node("Bar")

      expect(described_class.named(written)).to eq([written, false, nil])
    end

    # A name fetched as data is looked up in whatever `self` is when the line
    # runs, which the writing scope does not decide — so the NAME travels and
    # the namespace is the caller's to supply.
    it "answers the name for a constant fetched as data" do
      expect(described_class.named(node("const_get(:Bar)"))).to eq(["Bar", true, nil])
    end

    # The distinction is the point: the same name, written the two ways in one
    # body, reaches two different modules.
    it "tells the two apart" do
      expect(described_class.named(node("Bar"))[1]).to be(false)
      expect(described_class.named(node("const_get(:Bar)"))[1]).to be(true)
    end

    # `const_set` gives both answers at once: it names the constant AND is the
    # reason it exists, which is what a caller requiring prior declaration has to
    # tell apart.
    it "answers the name and the kind for a constant a `const_set` creates" do
      expect(described_class.named(node("const_set(:Bar, Module.new)"))).to eq(["Bar", true, "module"])
      expect(described_class.named(node("const_set(:Bar, Class.new)"))).to eq(["Bar", true, "class"])
    end

    # It names Bar, but says nothing about what Bar is, and a caller reading this
    # wants a type it can reopen.
    it "declines a `const_set` of something that is not a fresh namespace" do
      expect(described_class.named(node("const_set(:Bar, whatever)"))).to be_nil
      expect(described_class.named(node("const_set(:Bar, Struct.new(:a))"))).to be_nil
    end

    it "declines a `const_set` into another object's namespace" do
      expect(described_class.named(node("other.const_set(:Bar, Module.new)"))).to be_nil
    end

    it "answers nothing for an expression that names no constant" do
      expect(described_class.named(node("some_method"))).to be_nil
      expect(described_class.named(node("@ivar"))).to be_nil
    end
  end

  describe ".fetched_name" do
    it "reads a string as readily as a symbol" do
      expect(described_class.fetched_name(node('const_get("Bar")'))).to eq("Bar")
    end

    it "reads the `send` spelling as the call it is" do
      expect(described_class.fetched_name(node("send(:const_get, :Bar)"))).to eq("Bar")
    end

    # Which constant an interpolated name reaches is a runtime answer.
    it "declines a computed name" do
      expect(described_class.fetched_name(node('const_get(:"#{prefix}Bar")'))).to be_nil
      expect(described_class.fetched_name(node("const_get(name)"))).to be_nil
    end

    # A receiver names another object, and which module that is is not something
    # the source says.
    it "declines a fetch from another object" do
      expect(described_class.fetched_name(node("other.const_get(:Bar)"))).to be_nil
    end

    it "reads a fetch written on `self`" do
      expect(described_class.fetched_name(node("self.const_get(:Bar)"))).to eq("Bar")
    end

    # It asks whether a constant is there rather than naming one to use, and the
    # caller answers that with the declarations it has seen.
    it "declines `const_defined?`" do
      expect(described_class.fetched_name(node("const_defined?(:Bar)"))).to be_nil
    end
  end

  describe ".literal_name" do
    it "reads a name written as data" do
      expect(described_class.literal_name(node(":Bar"))).to eq("Bar")
      expect(described_class.literal_name(node('"Bar"'))).to eq("Bar")
    end

    # No constant may be named this, so the data is not a constant name — the
    # check `SendCall.literal_name` deliberately does not make, since nearly
    # every name is a method name.
    it "declines a name no constant may have" do
      expect(described_class.literal_name(node(":bar"))).to be_nil
      expect(described_class.literal_name(node(":@bar"))).to be_nil
    end

    it "declines a name that is not written as data at all" do
      expect(described_class.literal_name(node("Bar"))).to be_nil
      expect(described_class.literal_name(node("name"))).to be_nil
    end
  end
end
