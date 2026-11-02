# frozen_string_literal: true

RSpec.describe RbsInfer::Signatures::GenericArguments do
  let(:declared) { RbsInfer::Signatures::RbsDefinitionResolver.new.method(:declaration) }

  def applied(rbs) = described_class.apply(rbs, declared: declared)

  it "writes untyped for each parameter of a generic class written with no arguments" do
    expect(applied("class Foo\n  @list: Array\n  def pairs: () -> Hash\nend\n"))
      .to eq("class Foo\n  @list: Array[untyped]\n  def pairs: () -> Hash[untyped, untyped]\nend\n")
  end

  it "completes a generic module a mixin names with no arguments" do
    expect(applied("class Foo\n  include Enumerable\nend\n")).to eq("class Foo\n  include Enumerable[untyped]\nend\n")
  end

  it "resolves a nested name from where it is written" do
    expect(applied("class Enumerator[unchecked out E, out R = void]\n  def lazy: () -> Lazy\nend\n"))
      .to include("def lazy: () -> Lazy[untyped, untyped]")
  end

  it "leaves a name with arguments, a singleton and a non-generic class as they are" do
    rbs = "class Foo\n  @set: Set[Integer]\n  def klass: () -> singleton(Array)\n  def name: () -> String\nend\n"

    expect(applied(rbs)).to eq(rbs)
  end
end
