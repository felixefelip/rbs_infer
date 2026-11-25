# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::NewCallCollector::Scope do
  def scope = described_class.new(local_var_types: {}, caller_class_name: nil)

  def declaration(source, name)
    found = nil
    walk = lambda do |node|
      declares = node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      found ||= node if declares && node.constant_path.slice == name
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse(source).value)
    found
  end

  def class_name_inside(source, *names)
    scope = self.scope
    name = nil
    visit = lambda do |remaining|
      next name = scope.lexical_class_name if remaining.empty?

      node = declaration(source, remaining.first)
      entered = node.is_a?(Prism::ModuleNode) ? :in_module : :in_class
      scope.public_send(entered, node) { visit.call(remaining.drop(1)) }
    end
    visit.call(names)
    name
  end

  it "names a class written inside a module with the module" do
    source = "module Shop\n  class Reader\n  end\nend\n"

    expect(class_name_inside(source, "Shop", "Reader")).to eq("Shop::Reader")
  end

  it "names a class written inside a class inside a module with both" do
    source = "module Shop\n  class Reader\n    class Page\n    end\n  end\nend\n"

    expect(class_name_inside(source, "Shop", "Reader", "Page")).to eq("Shop::Reader::Page")
  end

  it "names a top-level class by itself" do
    expect(class_name_inside("class Reader\nend\n", "Reader")).to eq("Reader")
  end
end
