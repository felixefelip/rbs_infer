# frozen_string_literal: true

require "spec_helper"

RSpec.describe RbsInfer::Inference::UnreachedMembers do
  def member(kind, name, owner: nil)
    RbsInfer::Inference::Member.new(kind: kind, name: name, owner: owner)
  end

  let(:owner_of) { ->(m) { m.owner ? "Store::#{m.owner}" : "Store" } }

  it "drops the methods the checker found a class body never defines, on either side" do
    members = [member(:method, "[]"), member(:method, "[]="),
               member(:class_method, "build"), member(:class_method, "make")]

    described_class.reject!(members, unreached: Set["Store#[]", "Store.build"], owner_of: owner_of)

    expect(members.map(&:name)).to eq(%w[[]= make])
  end

  it "asks under the member's owner, and keeps anything that is not a method" do
    members = [member(:method, "tag", owner: "Helpers"), member(:method, "tag"), member(:constant, "tag")]

    described_class.reject!(members, unreached: Set["Store::Helpers#tag"], owner_of: owner_of)

    expect(members.map { |m| [m.kind, m.owner] }).to eq([[:method, nil], [:constant, nil]])
  end
end
