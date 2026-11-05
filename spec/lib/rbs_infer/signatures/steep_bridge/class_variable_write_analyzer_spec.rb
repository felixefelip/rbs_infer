# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge::ClassVariableWriteAnalyzer, :dummy_app do
  let(:bridge) do
    RbsInfer::Signatures::SteepBridge.new(literal_method_registry: Steep::Project::LiteralMethodRegistry.new,
                                          constructor_bindings: Steep::Project::ConstructorBindingRegistry.new)
  end
  let(:analyzer) { described_class.new(steep_bridge: bridge) }

  def by_owner(code, target_class: "Foo", owners: [])
    analyzer.by_owner(Struct.new(:source, :path).new(code, nil), target_class:, owners:)
  end

  it "declares what a class body assigns as non-nilable" do
    expect(by_owner(<<~RUBY)).to eq(nil => { "@@x" => "String" })
      class Foo
        @@x = "hello"
      end
    RUBY
  end

  it "makes nilable what only a method assigns" do
    expect(by_owner(<<~RUBY)).to eq(nil => { "@@x" => "String?" })
      class Foo
        def self.x = @@x ||= "hello"
      end
    RUBY
  end

  it "unites every assignment" do
    expect(by_owner(<<~RUBY)).to eq(nil => { "@@x" => "String | Integer" })
      class Foo
        @@x = "hello"

        def self.reset
          @@x = 1
        end
      end
    RUBY
  end

  it "ignores an assignment in a branch the checker proved cannot run" do
    expect(by_owner(<<~RUBY)).to eq(nil => { "@@x" => "String" })
      class Foo
        @@x = "hello"

        if false
          @@x = 1
        end
      end
    RUBY
  end

  it "keeps a nested module's variables under its name" do
    expect(by_owner(<<~RUBY, owners: ["Bar"])).to eq(nil => {}, "Bar" => { "@@y" => "Integer" })
      class Foo
        module Bar
          @@y = 1
        end
      end
    RUBY
  end

  it "answers nothing for a file it could not parse" do
    expect(analyzer.by_owner(nil, target_class: "Foo", owners: [])).to eq({})
  end
end
