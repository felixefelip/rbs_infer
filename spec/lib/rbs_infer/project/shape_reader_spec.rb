# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "prism"

RSpec.describe RbsInfer::Project::StoredBlockReplayExpander::ShapeReader do
  def forwards(source)
    node = RbsInfer::Analyzer.find_all_nodes(Prism.parse(source).value) { |n| n.is_a?(Prism::DefNode) }.first
    reading = RbsInfer::Project::StoredBlockReplayExpander::NodeReading
    handed = reading.handed_names(node.body, reading.parameter_names(node.parameters))
    described_class.forward_shapes(node.body, handed)
  end

  it "reads a forward to a method of the object it was handed" do
    expect(forwards("def bazinga(mod) = mod.bazingado(self)")).to eq([["mod", "bazingado", false]])
  end

  it "reads a forward through `singleton_class`, and says which table" do
    expect(forwards(<<~RUBY)).to eq([["obj", "include", true]])
      def extend_object(obj)
        obj.singleton_class.include(self)
        obj
      end
    RUBY
  end

  it "tells the two tables apart in one body" do
    expect(forwards(<<~RUBY)).to eq([["mod", "include", false], ["mod", "include", true]])
      def both(mod)
        mod.include(self)
        mod.singleton_class.include(self)
      end
    RUBY
  end

  it "reads the hop through `send`" do
    expect(forwards("def extend_object(obj) = obj.singleton_class.send(:include, self)"))
      .to eq([["obj", "include", true]])
  end

  it "declines a receiver it was not handed" do
    expect(forwards("def go(mod) = Other.singleton_class.include(self)")).to be_empty
  end

  it "declines a `singleton_class` that takes arguments" do
    expect(forwards("def go(mod) = mod.singleton_class(:x).include(self)")).to be_empty
  end

  it "declines a call that does not hand `self` over" do
    expect(forwards("def go(mod) = mod.singleton_class.include(Other)")).to be_empty
  end
end
