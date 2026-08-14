# frozen_string_literal: true

require "spec_helper"
require "rbs"

# Picking an overload by the call's argument types. Without them the choice is
# DECLARATION ORDER, which across reopens is load order and carries no meaning:
# `bigdecimal`'s RBS reopens `Integer` with `def +: (BigDecimal) -> BigDecimal
# | ...`, so `age + 10` resolved to `BigDecimal` while its own body was
# `Integer` — the emitted RBS contradicted the source it was generated from.
RSpec.describe RbsInfer::Signatures::RbsDefinitionResolver do
  subject(:resolver) { described_class.new }

  # `Definition::Method#defs` entries answer `#type` with a MethodType; that is
  # all the selection reads, so a Struct stands in for the whole definition.
  TypeDef = Struct.new(:type)

  def defs(*method_types)
    method_types.map { |mt| TypeDef.new(RBS::Parser.parse_method_type(mt)) }
  end

  # The real shape from the bigdecimal reopen: the BigDecimal overload is
  # FIRST, so "the first that formats" answers BigDecimal for `2 + 2`.
  let(:integer_plus) do
    defs("(::BigDecimal) -> ::BigDecimal",
         "(::Integer) -> ::Integer",
         "(::Float) -> ::Float")
  end

  describe "#select_overload" do
    it "picks the overload whose parameter names the argument's type" do
      selected = resolver.select_overload(integer_plus, ["Integer"])

      expect(selected.type.type.return_type.to_s).to eq("::Integer")
    end

    it "matches across the `::` prefix, which is the same type written twice" do
      expect(resolver.select_overload(integer_plus, ["::Float"]).type.type.return_type.to_s)
        .to eq("::Float")
    end

    # Every "says nothing" case, each of which leaves the previous walk in place.
    it "says nothing without argument types" do
      expect(resolver.select_overload(integer_plus, nil)).to be_nil
    end

    it "says nothing when an argument's type is unknown" do
      expect(resolver.select_overload(integer_plus, [nil])).to be_nil
    end

    it "says nothing when no overload takes that type" do
      expect(resolver.select_overload(integer_plus, ["String"])).to be_nil
    end

    it "says nothing when the arity does not match" do
      expect(resolver.select_overload(integer_plus, %w[Integer Integer])).to be_nil
    end

    it "says nothing when two overloads name the same type" do
      ambiguous = defs("(::Integer) -> ::Integer", "(::Integer) -> ::Float")

      expect(resolver.select_overload(ambiguous, ["Integer"])).to be_nil
    end
  end

  describe "#accepts_arguments?" do
    def method_type(source) = RBS::Parser.parse_method_type(source)

    it "accepts a method type whose required positionals are exactly these types" do
      expect(resolver.accepts_arguments?(method_type("(::Integer) -> ::Integer"), ["Integer"])).to be(true)
    end

    # These all describe argument lists a positional-only comparison cannot
    # stand for, so calling them a match would be the guess this avoids.
    it "declines optional positionals" do
      expect(resolver.accepts_arguments?(method_type("(?::Integer) -> ::Integer"), ["Integer"])).to be(false)
    end

    it "declines a rest positional" do
      expect(resolver.accepts_arguments?(method_type("(*::Integer) -> ::Integer"), ["Integer"])).to be(false)
    end

    it "declines keywords" do
      expect(resolver.accepts_arguments?(method_type("(::Integer, base: ::Integer) -> ::Integer"), ["Integer"]))
        .to be(false)
    end
  end
end
