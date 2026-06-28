require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ConstantArgTypeResolver do
  # A fake bridge exercising the two cross-file outcomes without a real Steep
  # environment: a value constant resolves to a type, a class/module is
  # recognized as such, everything else is unknown.
  FakeBridge = Struct.new(:constants, :classes) do
    def constant_type_from_env(name, namespace:)
      constants[name]
    end

    def class_or_module?(name, namespace:)
      classes.include?(name)
    end
  end

  describe "#resolve" do
    it "resolves a same-file value constant to its value type" do
      resolver = described_class.new(steep_bridge: nil, caller_constant_types: { "CODE_LENGTH" => "Integer" })
      expect(resolver.resolve(name: "CODE_LENGTH", namespace: nil)).to eq("Integer")
    end

    it "prefers the same-file type over the cross-file env" do
      bridge = FakeBridge.new({ "CODE_LENGTH" => "Float" }, [])
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: { "CODE_LENGTH" => "Integer" })
      expect(resolver.resolve(name: "CODE_LENGTH", namespace: nil)).to eq("Integer")
    end

    it "falls back to the cross-file env for a constant defined elsewhere" do
      bridge = FakeBridge.new({ "Settings::CODE_LEN" => "Integer" }, [])
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "Settings::CODE_LEN", namespace: "Widget")).to eq("Integer")
    end

    it "keeps the bare name for a class/module reference" do
      bridge = FakeBridge.new({}, ["User"])
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "User", namespace: nil)).to eq("User")
    end

    it "returns nil for an unresolved constant (caller emits untyped, never a poisoning bare name)" do
      bridge = FakeBridge.new({}, [])
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "UNDEFINED_CONST", namespace: nil)).to be_nil
    end

    it "without a Steep env, still resolves a same-file constant" do
      resolver = described_class.new(steep_bridge: nil, caller_constant_types: { "CODE_LENGTH" => "Integer" })
      expect(resolver.resolve(name: "CODE_LENGTH", namespace: nil)).to eq("Integer")
    end

    it "without a Steep env, returns nil for an unclassifiable constant (never a bare name, #56)" do
      resolver = described_class.new(steep_bridge: nil, caller_constant_types: {})
      expect(resolver.resolve(name: "User", namespace: nil)).to be_nil
    end

    it "returns nil for a nil node name" do
      resolver = described_class.new(steep_bridge: nil, caller_constant_types: {})
      expect(resolver.resolve(name: nil, namespace: nil)).to be_nil
    end
  end
end
