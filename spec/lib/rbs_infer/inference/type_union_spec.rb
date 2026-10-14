# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::TypeUnion do
  it "unions distinct types preserving the original form" do
    expect(described_class.of(["String", "::MyApp::Entity"]))
      .to eq("(String | ::MyApp::Entity)")
  end

  it "emits a single type verbatim (keeps the absolute `::`)" do
    expect(described_class.of(["::MyApp::Entity"])).to eq("::MyApp::Entity")
  end

  it "flattens pre-existing unions instead of nesting parens" do
    expect(described_class.of(["(String | Symbol)", "Symbol"]))
      .to eq("(String | Symbol)")
  end

  it "does not flatten a `|` nested inside generics" do
    expect(described_class.of(["Array[String | Symbol]"]))
      .to eq("Array[String | Symbol]")
  end

  it "drops untyped when at least one resolved type exists" do
    expect(described_class.of(%w[untyped String])).to eq("String")
  end

  # The same intersection arrives parenthesized when read back from an RBS declaration
  # and bare from Steep. A textual key made them two members of a bogus union.
  it "collapses two spellings of the same type" do
    expect(described_class.of(["(Post & Post::Validated)", "Post & Post::Validated"]))
      .to eq("(Post & Post::Validated)")
  end

  it "collapses spellings differing only in the absolute prefix" do
    expect(described_class.of(["User & ::User::Validated", "(::User & ::User::Validated)"]))
      .to eq("User & ::User::Validated")
  end

  # The two branches of a call on a nilable receiver answer with opposite
  # constants (`Model#present?: () -> true` / `NilClass#present?: () -> false`),
  # so the union that spans them is the whole of `bool` and should say so.
  it "collapses the two boolean constants into bool" do
    expect(described_class.of(%w[true false])).to eq("bool")
  end

  it "drops a boolean constant bool already covers" do
    expect(described_class.of(%w[bool false])).to eq("bool")
  end

  it "keeps nil alongside the collapsed bool" do
    expect(described_class.of(%w[true false nil])).to eq("bool?")
  end

  # `NilClass#to_s: () -> ""` against any other branch's `String`.
  it "drops a literal its own class already covers" do
    expect(described_class.of(["String", '""'])).to eq("String")
    expect(described_class.of([":a", "Symbol"])).to eq("Symbol")
  end

  it "keeps a literal whose class is not in the union" do
    expect(described_class.of(['""', "Symbol"])).to eq('("" | Symbol)')
  end

  it "reads `T?` and `T | nil` as one type" do
    expect(described_class.of(["(User & User::Validated)", "User?", "User", "nil"]))
      .to eq("((User & User::Validated) | User)?")
    expect(described_class.of(["Example3::User?", "nil", "Example3::User"])).to eq("Example3::User?")
  end
end
