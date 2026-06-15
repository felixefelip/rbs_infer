# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::TargetDiscovery do
  def discover(source)
    visitor = described_class.new
    Prism.parse(source).value.accept(visitor)
    visitor
  end

  it "discovers a single top-level class" do
    d = discover(<<~RUBY)
      class User
        def name; end
      end
    RUBY

    expect(d.declaration_targets).to eq([{ name: "User", is_module: false }])
    expect(d.include_targets).to be_empty
  end

  it "discovers sibling top-level declarations with their kind" do
    d = discover(<<~RUBY)
      class Foo; end
      module Bar; end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Foo", is_module: false },
      { name: "Bar", is_module: true },
    ])
  end

  it "treats blocks as transparent (a module inside to_prepare is top-level)" do
    d = discover(<<~RUBY)
      Rails.application.config.to_prepare do
        module Authorize
          def call; end
        end
      end
    RUBY

    expect(d.declaration_targets).to eq([{ name: "Authorize", is_module: true }])
  end

  it "excludes declarations nested inside another class/module" do
    d = discover(<<~RUBY)
      class Report
        module Formatting
          def title; end
        end
        include Formatting
      end
    RUBY

    # Only the top-level Report; Formatting is emitted in place by the
    # owner mechanism, not as a separate target.
    expect(d.declaration_targets).to eq([{ name: "Report", is_module: false }])
    expect(d.include_targets).to be_empty
  end

  it "collects Receiver.include calls as include targets" do
    d = discover(<<~RUBY)
      Foo::Bar.include Mixin
      Foo::Bar.include OtherMixin
      Baz.include Mixin
    RUBY

    expect(d.include_targets).to eq({
      "Foo::Bar" => ["Mixin", "OtherMixin"],
      "Baz" => ["Mixin"],
    })
  end

  it "does not treat an implicit include (self receiver) as a reopen target" do
    d = discover(<<~RUBY)
      class Foo
        include Mixin
      end
    RUBY

    expect(d.include_targets).to be_empty
  end
end
