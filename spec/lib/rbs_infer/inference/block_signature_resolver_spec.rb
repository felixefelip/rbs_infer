# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# The four passes themselves are exercised end to end (the block specs beside this
# one, plus the dummy's snapshots) — what is checked here is the seam the extraction
# created: the one predicate the Analyzer asks BEFORE the passes run, and the guard
# that lets a consumer with no parsed target call `apply` anyway.
RSpec.describe RbsInfer::Inference::BlockSignatureResolver do
  def member(kind: :method, name: "run", signature: "run: () -> untyped")
    RbsInfer::Inference::Member.new(kind: kind, name: name, signature: signature, visibility: :public, owner: nil)
  end

  describe ".untyped_block_return?" do
    it "is true for a method whose block return is still open" do
      expect(described_class.untyped_block_return?(
        member(signature: "run: () { (String) -> untyped } -> untyped")
      )).to be(true)
    end

    it "is false once the block return has been filled in" do
      expect(described_class.untyped_block_return?(
        member(signature: "run: () { (String) -> Integer } -> untyped")
      )).to be(false)
    end

    # A member whose signature a later pass still has to fill in — the predicate runs
    # over everything the collector produced, not only the ones with a method type.
    it "survives a member with no signature yet" do
      expect(described_class.untyped_block_return?(member(signature: nil))).to be(false)
    end

    it "is false for a member that is not a method" do
      expect(described_class.untyped_block_return?(
        member(kind: :include, name: "Comparable", signature: "Comparable")
      )).to be(false)
    end
  end

  describe "#apply" do
    # `parsed_target` is nil for a consumer that never parsed a target file, and the
    # bridge has nothing to be asked about. Guarded once here rather than four times.
    it "does nothing without a parsed target" do
      target = member(signature: "run: () ?{ (*untyped) -> untyped } -> untyped")
      resolver = described_class.new(parsed_target: nil, parsed_block_return_target: nil, steep_bridge: nil)

      expect { resolver.apply([target], caller_returns: nil) }.not_to change(target, :signature)
    end
  end
end
