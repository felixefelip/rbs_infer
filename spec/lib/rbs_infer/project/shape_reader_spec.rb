# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "prism"

# `ShapeReader` is a module of pure functions — a body and the names it was
# handed go in, a tuple or nil comes out — and its own comment says so: the
# readings "can be checked against a source string with nothing else set up"
# (felixefelip/rbs_infer#303). Until now nothing did; they were exercised only
# through `expand`, which answers about a whole file.
#
# This file starts with the one reading `extend` depends on
# (felixefelip/rbs_infer#311).
RSpec.describe RbsInfer::Project::StoredBlockReplayExpander::ShapeReader do
  # The single `def` in `source`, with the names it was handed — which is the
  # method's parameters plus the parameters of blocks passed to calls on them,
  # exactly as `Collector#collect_method_shape` computes them.
  def forwards(source)
    node = RbsInfer::Analyzer.find_all_nodes(Prism.parse(source).value) { |n| n.is_a?(Prism::DefNode) }.first
    handed = RbsInfer::Project::StoredBlockReplayExpander::NodeReading.handed_names(node.body, RbsInfer::Project::StoredBlockReplayExpander::NodeReading.parameter_names(node.parameters))
    described_class.forward_shapes(node.body, handed)
  end

  # `mod.bazingado(self)` — the hop this shape was written for.
  it "reads a forward to a method of the object it was handed" do
    expect(forwards("def bazinga(mod) = mod.bazingado(self)")).to eq([["mod", "bazingado", false]])
  end

  # The same hop asked about the other method table, which is what
  # `Module#extend_object` is written as. Read bare, this line was no shape at
  # all — and that is how `extend` could not be derived from `include`.
  it "reads a forward through `singleton_class`, and says which table" do
    expect(forwards(<<~RUBY)).to eq([["obj", "include", true]])
      def extend_object(obj)
        obj.singleton_class.include(self)
        obj
      end
    RUBY
  end

  # The two are distinguished, not merged: `mod.include(self)` and
  # `mod.singleton_class.include(self)` reach different methods, and a shape
  # that answered the same for both would send a block to the wrong table.
  it "tells the two tables apart in one body" do
    expect(forwards(<<~RUBY)).to eq([["mod", "include", false], ["mod", "include", true]])
      def both(mod)
        mod.include(self)
        mod.singleton_class.include(self)
      end
    RUBY
  end

  # Through a `send`, because that is how the transcriptions reach a private
  # hook — `rb_funcall` dispatches ignoring visibility.
  it "reads the hop through `send`" do
    expect(forwards("def extend_object(obj) = obj.singleton_class.send(:include, self)"))
      .to eq([["obj", "include", true]])
  end

  # The parameter restriction is the whole conservatism, and `singleton_class`
  # does not relax it: the hop is safe only because the object it lands on is
  # decided by the one we were handed.
  it "declines a receiver it was not handed" do
    expect(forwards("def go(mod) = Other.singleton_class.include(self)")).to be_empty
  end

  # `singleton_class` takes no arguments. A same-named method that does is
  # somebody else's and says nothing about a method table.
  it "declines a `singleton_class` that takes arguments" do
    expect(forwards("def go(mod) = mod.singleton_class(:x).include(self)")).to be_empty
  end

  # What makes it a FORWARD is that `self` arrives at the callee. A call that
  # passes anything else is an ordinary message the method happens to send.
  it "declines a call that does not hand `self` over" do
    expect(forwards("def go(mod) = mod.singleton_class.include(Other)")).to be_empty
  end
end
