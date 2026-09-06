# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# `CallGraph` answers where a call ends up, walked over the shapes a file was
# read as writing. Asked directly here, because the one thing this file pins is
# not reachable through `expand` yet: `Module#extend_object` is the only forward
# in the corpus written through `singleton_class`, and nothing asks the graph
# about `extend_object` until the ancestry table is derived from it
# (felixefelip/rbs_infer#311, step 3). A branch no example reaches is a branch
# nobody has checked.
RSpec.describe RbsInfer::Project::StoredBlockReplayExpander::CallGraph do
  # Fully qualified rather than `include`d: the block a `describe` takes is
  # `class_eval`'d, so its lexical scope is this file's top level and a constant
  # named in a helper never reaches the example group's ancestors.
  SHAPES = RbsInfer::Project::StoredBlockReplayExpander::Shapes

  def graph(forwards:, delegations: [])
    described_class.new(replay_methods: [], readers: [], inward_replays: [], literal_replays: [],
                        forwards: forwards, delegations: delegations, storages: [])
  end

  def forward(callee:, singleton:)
    SHAPES::ForwardMethod.new(owner: "Module", method: "hand_over", parameter: "obj", callee: callee, singleton: singleton)
  end

  # `mod.include(self)`: the callee is looked up where the argument's own
  # methods are.
  it "looks a bare forward up in the argument's provider" do
    reached = graph(forwards: [forward(callee: "include", singleton: false)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["DSL", "include"]])
  end

  # `mod.singleton_class.include(self)`: a different object, so a different
  # method table, so a different owner. Reading both the same way would report a
  # method the argument does not answer to.
  it "looks a forward through `singleton_class` up in the argument's singleton" do
    reached = graph(forwards: [forward(callee: "include", singleton: true)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["singleton(DSL)", "include"]])
  end

  # Both spellings in one body reach two distinct methods, and the graph reports
  # two — which is what makes the flag worth carrying rather than re-deriving.
  it "reports the two tables as two destinations" do
    reached = graph(forwards: [forward(callee: "include", singleton: false),
                               forward(callee: "include", singleton: true)])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["DSL", "include"], ["singleton(DSL)", "include"]])
  end

  # The delegation hop still applies on top: `keeper` is asked of the owner the
  # table lookup landed on, not of the raw provider.
  it "follows a delegation from the singleton owner" do
    delegation = SHAPES::Delegation.new(owner: "singleton(DSL)", method: "include", target: "Holder", callee: "keep")
    reached = graph(forwards: [forward(callee: "include", singleton: true)], delegations: [delegation])
              .keepers_for("Module", "hand_over", "DSL")

    expect(reached).to eq([["Holder", "keep"]])
  end
end
