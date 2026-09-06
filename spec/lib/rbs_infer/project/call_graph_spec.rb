# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayExpander::CallGraph do
  SHAPES = RbsInfer::Project::StoredBlockReplayExpander::Shapes

  def graph(forwards:, delegations: [])
    described_class.new(replay_methods: [], readers: [], inward_replays: [], literal_replays: [],
                        forwards: forwards, delegations: delegations, storages: [])
  end

  def forward(callee:, singleton:)
    SHAPES::ForwardMethod.new(owner: "Module", method: "hand_over", parameter: "obj",
                              callee: callee, singleton: singleton)
  end

  it "looks a bare forward up in the argument's provider" do
    reached = graph(forwards: [forward(callee: "include", singleton: false)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["DSL", "include"]])
  end

  it "looks a forward through `singleton_class` up in the argument's singleton" do
    reached = graph(forwards: [forward(callee: "include", singleton: true)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["singleton(DSL)", "include"]])
  end

  it "reports the two tables as two destinations" do
    reached = graph(forwards: [forward(callee: "include", singleton: false),
                               forward(callee: "include", singleton: true)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["DSL", "include"], ["singleton(DSL)", "include"]])
  end

  it "follows a delegation from the singleton owner" do
    delegation = SHAPES::Delegation.new(owner: "singleton(DSL)", method: "include",
                                        target: "Holder", callee: "keep")
    reached = graph(forwards: [forward(callee: "include", singleton: true)], delegations: [delegation])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["Holder", "keep"]])
  end
end
