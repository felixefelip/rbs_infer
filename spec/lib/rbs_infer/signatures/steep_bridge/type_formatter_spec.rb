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
  end
end
