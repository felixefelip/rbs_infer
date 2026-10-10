require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge::TypeFormatter, :dummy_app do
  describe ".format_type" do
    it "collapses Steep Logic types to bool (regression for Logic::Not leaking into RBS)" do
      # `!@x.nil?` and similar predicate bodies type as
      # `Steep::AST::Types::Logic::*` internally — unprintable types
      # Steep uses for predicate flow narrowing. Without explicit
      # handling, `to_s` emits `<% Steep::AST::Types::Logic::Not %>`
      # which leaks into the generated RBS as a literal `Logic::Not`
      # string. Verify the helper collapses each Logic type to `bool`.
      expect(RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(Steep::AST::Types::Logic::Not.instance)).to eq("bool")
      expect(RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(Steep::AST::Types::Logic::ReceiverIsNil.instance)).to eq("bool")
      expect(RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(Steep::AST::Types::Logic::ReceiverIsArg.instance)).to eq("bool")
      expect(RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(Steep::AST::Types::Logic::ArgIsReceiver.instance)).to eq("bool")
    end

    # `(^() -> Symbol | nil)` collapsed to `^() -> Symbol?`, which is a proc
    # whose RETURN is optional — the proc itself still mandatory, so Steep
    # rejected the very body the type was read from
    # (felixefelip/rbs_infer#237). The `?` goes through `nilablize` now, which
    # is where the question of what may carry one bare is answered.
    it "parenthesizes a proc before making it optional" do
      proc_type = Steep::AST::Types::Proc.new(
        type: Steep::Interface::Function.new(
          params: Steep::Interface::Function::Params.empty,
          return_type: Steep::AST::Builtin::Symbol.instance_type,
          location: nil
        ),
        block: nil,
        self_type: nil
      )
      union = Steep::AST::Types::Union.build(types: [proc_type, Steep::AST::Builtin.nil_type])

      expect(described_class.format_type(union)).to eq("(^() -> Symbol)?")
    end

    it "erases an inference variable Steep never solved" do
      variable = Steep::AST::Types::Var.fresh(:T)

      expect(variable.to_s).to match(/\AT\(\d+\)\z/)
      expect(described_class.format_type(variable)).to eq("untyped")
      expect(
        described_class.format_type(
          Steep::AST::Types::Union.build(types: [Steep::AST::Builtin::Object.instance_type, variable])
        )
      ).to eq("untyped")
    end

    # A type RBS cannot spell is written as the one it can, nested or not. Its
    # `to_s` is for diagnostics: `::Reflection{@name: :posts}` would be a
    # syntax error in the file being written.
    it "writes a type RBS cannot spell as its back type" do
      reflection = Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::Reflection"), args: [])
      state = Steep::AST::Types::ObjectState.new(
        back_type: reflection,
        ivars: { :@name => Steep::AST::Types::Literal.new(value: :posts) }
      )
      set = Steep::AST::Types::FiniteSet.new(types: [Steep::AST::Types::Literal.new(value: "a")])

      expect(described_class.format_type(state)).to eq("Reflection")
      expect(described_class.format_type(Steep::AST::Types::Union.build(types: [state,
                                                                                Steep::AST::Builtin.nil_type]))).to eq("Reflection?")
      expect(described_class.format_type(set)).to eq('Set["a"]')
    end

    it "leaves an RBS type alone, which carries variables it cannot substitute" do
      expect(described_class.format_type(RBS::Parser.parse_type("::Array[Elem]"))).to eq("Array[Elem]")
    end
  end
end
