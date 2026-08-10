# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# The one place that knows how to read a `send` (felixefelip/rbs_infer#205). Its answer is a
# real `Prism::CallNode` — the same node under the method's own name, without the name
# literal — so every reader downstream works on it untouched and learns nothing about `send`.
RSpec.describe RbsInfer::Inference::SendCall do
  def desugar(source)
    described_class.desugar(Prism.parse(source).value.statements.body.first)
  end

  it "answers with the call the send stands for" do
    call = desugar('obj.send(:stamp, "post")')

    expect(call.name).to eq(:stamp)
    expect(call.arguments.arguments.map(&:unescaped)).to eq(["post"])
  end

  it "keeps the receiver, so the caller still resolves whose method it is" do
    expect(desugar('obj.send(:stamp, "post")').receiver.name).to eq(:obj)
  end

  it "keeps a bare call bare" do
    expect(desugar('send(:stamp, "post")').receiver).to be_nil
  end

  # `send(:each) { … }` passes the block to `each`.
  it "keeps the block" do
    call = desugar("obj.send(:each) { |x| x }")

    expect(call.name).to eq(:each)
    expect(call.block).to be_a(Prism::BlockNode)
    expect(call.arguments.arguments).to be_empty
  end

  it "reads all three spellings" do
    expect(desugar("obj.send(:stamp)").name).to eq(:stamp)
    expect(desugar("obj.__send__(:stamp)").name).to eq(:stamp)
    expect(desugar("obj.public_send(:stamp)").name).to eq(:stamp)
  end

  it "reads a string name as well as a symbol" do
    expect(desugar('obj.send("stamp")').name).to eq(:stamp)
  end

  it "keeps the real name of a predicate and of a writer" do
    expect(desugar("obj.send(:stamped?)").name).to eq(:stamped?)
    expect(desugar('obj.send(:title=, "t")').name).to eq(:title=)
  end

  # Nothing static says which method these are, and a guess would be worse than no answer.
  it "declines a computed name" do
    expect(desugar("obj.send(name)")).to be_nil
    expect(desugar('obj.send(:"ti#{part}")')).to be_nil
    expect(desugar("obj.send(SOME_CONST)")).to be_nil
  end

  it "declines a send with nothing to name" do
    expect(desugar("obj.send")).to be_nil
  end

  it "declines an ordinary call" do
    expect(desugar('obj.stamp("post")')).to be_nil
    expect(desugar('obj.resend(:stamp)')).to be_nil
  end

  it "declines a node that is not a call" do
    expect(described_class.desugar(Prism.parse("1 + 1").value)).to be_nil
  end
end
