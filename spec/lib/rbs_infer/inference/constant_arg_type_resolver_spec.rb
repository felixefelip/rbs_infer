require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ConstantArgTypeResolver do
  # A fake bridge exercising the two cross-file outcomes without a real Steep
  # environment: a value constant resolves to a type, a class/module resolves to the
  # FULLY QUALIFIED name the env matched (`classes` maps written name => that answer),
  # everything else is unknown.
  FakeBridge = Struct.new(:constants, :classes) do
    def constant_type_from_env(name, namespace:)
      constants[name]
    end

    def class_or_module_name(name, namespace:)
      classes[name]
    end
  end

  describe "#resolve" do
    it "resolves a same-file value constant to its value type" do
      resolver = described_class.new(steep_bridge: nil, caller_constant_types: { "CODE_LENGTH" => "Integer" })
      expect(resolver.resolve(name: "CODE_LENGTH", namespace: nil)).to eq("Integer")
    end

    it "prefers the same-file type over the cross-file env" do
      bridge = FakeBridge.new({ "CODE_LENGTH" => "Float" }, {})
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: { "CODE_LENGTH" => "Integer" })
      expect(resolver.resolve(name: "CODE_LENGTH", namespace: nil)).to eq("Integer")
    end

    it "falls back to the cross-file env for a constant defined elsewhere" do
      bridge = FakeBridge.new({ "Settings::CODE_LEN" => "Integer" }, {})
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "Settings::CODE_LEN", namespace: "Widget")).to eq("Integer")
    end

    it "resolves a class/module reference to its singleton type" do
      # `foo(User)` passes the class object, whose value type is
      # `singleton(User)` — not the instance `User`.
      bridge = FakeBridge.new({}, { "User" => "::User" })
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "User", namespace: nil)).to eq("singleton(::User)")
    end

    # The emitted type has to survive being written into a signature that lives in
    # another namespace: `include Slots` inside `class IncludedHook` means
    # `::IncludedHook::Slots`, and `singleton(Slots)` inside `class Module` would mean
    # `::Slots` — a name that need not exist, which is invalid RBS wherever it lands.
    it "emits the qualified name the env matched, not the one the call site wrote" do
      bridge = FakeBridge.new({}, { "Slots" => "::IncludedHook::Slots" })
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "Slots", namespace: "IncludedHook")).to eq("singleton(::IncludedHook::Slots)")
    end

    # felixefelip/rbs_infer#295. `::Commentable` is not `Commentable`: the walk up
    # `namespace` offers the enclosing `Post::Commentable` first, and the module
    # would type its own argument. The env decides that — but only if the prefix
    # survives the trip, so it is the WRITTEN name that goes to the bridge.
    it "hands an absolute name to the env with its prefix intact" do
      bridge = FakeBridge.new({}, { "::Commentable" => "::Commentable", "Commentable" => "::Post::Commentable" })
      resolver = described_class.new(steep_bridge: bridge, caller_constant_types: {})
      expect(resolver.resolve(name: "::Commentable", namespace: "Post::Commentable")).to eq("singleton(::Commentable)")
    end

    it "returns nil for an unresolved constant (caller emits untyped, never a poisoning bare name)" do
      bridge = FakeBridge.new({}, {})
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
