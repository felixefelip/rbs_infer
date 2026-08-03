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
  end
end
