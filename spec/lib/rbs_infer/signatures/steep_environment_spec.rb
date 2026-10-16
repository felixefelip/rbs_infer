require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepEnvironment, :dummy_app do
  # The Steep type-checking context (subtyping + constant resolver, holding the
  # per-type method-shape cache) is shared at the class level so every Analyzer
  # reuses it instead of rebuilding shapes per file (felixefelip/rbs_infer#47).
  describe ".steep_context" do
    after { described_class.reset! }

    it "is memoized — the same context object across instances and calls" do
      ctx = described_class.steep_context
      expect(ctx).to be(described_class.steep_context)
      bridge = lambda do
        RbsInfer::Signatures::SteepBridge.new(literal_method_registry: Steep::Project::LiteralMethodRegistry.new,
                                              constructor_bindings: Steep::Project::ConstructorBindingRegistry.new)
      end
      expect(bridge.call.send(:steep_subtyping)).to be(ctx[:subtyping])
      expect(bridge.call.send(:steep_subtyping)).to be(bridge.call.send(:steep_subtyping))
    end

    it "is rebuilt after reset! (env may have changed between levels)" do
      before_ctx = described_class.steep_context
      described_class.reset!
      expect(described_class.steep_context).not_to be(before_ctx)
    end
  end
end
