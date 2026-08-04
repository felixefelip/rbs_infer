require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge::BlockAnalyzer, :dummy_app do
  subject(:bridge) { RbsInfer::Signatures::SteepBridge.new }

  # A method that only hands its block to someone else says nothing about it on
  # its own, so the CALLEE's declaration is the evidence (felixefelip/rbs_infer#149).
  describe "#forwarded_block_requirements" do
    it "takes the requirement from the callee of a named forward" do
      code = <<~RUBY
        class Foo
          def named(&block)
            Example17.new.with_token(&block)
          end
        end
      RUBY

      expect(bridge.forwarded_block_requirements(code)["named"])
        .to eq(required: true, params: ["String"])
    end

    # felixefelip/rbs_infer#174. The anonymous forward is the same statement
    # without a name, and Parser spells it as a `block_pass` whose child is nil
    # rather than an `lvar`. Reading only the `lvar` shape left the callee
    # unasked, so the method kept `?{ (*untyped) }` where the named spelling of
    # the very same body gets `{ (String) }`.
    it "reads an anonymous forward the same way" do
      code = <<~RUBY
        class Foo
          def anonymous(&)
            Example17.new.with_token(&)
          end
        end
      RUBY

      expect(bridge.forwarded_block_requirements(code)["anonymous"])
        .to eq(required: true, params: ["String"])
    end

    # `&:symbol` builds a proc on the spot; it is not this method's block, so it
    # is not a forward and the callee has no say over a block this method never
    # declared.
    it "does not read `&:symbol` as a forward" do
      code = <<~RUBY
        class Foo
          def symbol_proc(items)
            items.map(&:to_s)
          end
        end
      RUBY

      expect(bridge.forwarded_block_requirements(code)).to be_empty
    end
  end
end
