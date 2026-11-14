# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ClassMemberCollector::ProcParamCalls do
  def calls_for(source)
    def_node = Prism.parse(source).value.statements.body.first
    described_class.new(def_node.parameters, body: def_node.body).call
  end

  it "records one slot per argument, with `self` spelled as the receiver" do
    expect(calls_for("def m(fallback); fallback.call(self, key); end"))
      .to eq("fallback" => [[:self], [[1, 37, 1, 40]]])
  end

  it "reads a call through `&.`" do
    expect(calls_for("def m(fallback); fallback&.call(1); end").keys).to eq(["fallback"])
  end

  it "drops a parameter whose calls disagree on the arity" do
    expect(calls_for("def m(fallback); fallback.call(1); fallback.call(1, 2); end")).to eq({})
  end

  it "drops a parameter called with a splat" do
    expect(calls_for("def m(fallback, args); fallback.call(*args); end")).to eq({})
  end
end
