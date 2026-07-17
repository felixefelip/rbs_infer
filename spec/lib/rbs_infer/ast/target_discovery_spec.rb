# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::TargetDiscovery do
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

  it "excludes a nested module (the owner mechanism emits it in place)" do
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

  it "promotes a nested class to its own fully-qualified target" do
    d = discover(<<~RUBY)
      class Example2
        class User
          def name; end
        end

        class Foo
          def user=(value); end
        end

        def self.run; end
      end
    RUBY

    # The owner mechanism only ever handled nested modules, so without
    # promotion User/Foo's members were flattened into Example2.
    expect(d.declaration_targets).to eq([
      { name: "Example2", is_module: false },
      { name: "Example2::User", is_module: false },
      { name: "Example2::Foo", is_module: false },
    ])
  end

  it "qualifies a nested class against a compact enclosing path" do
    d = discover(<<~RUBY)
      class Admin::Report
        class Row
          def cells; end
        end

        def rows; end
      end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Admin::Report", is_module: false },
      { name: "Admin::Report::Row", is_module: false },
    ])
  end

  it "skips a pure namespace wrapper, keeping only the class it wraps" do
    d = discover(<<~RUBY)
      module Admin
        class User
          def name; end
        end
      end
    RUBY

    # `module Admin` has no members of its own, and RbsBuilder re-declares
    # the namespace around Admin::User anyway — emitting it as a target too
    # would only add a redundant empty block.
    expect(d.declaration_targets).to eq([{ name: "Admin::User", is_module: false }])
  end

  it "keeps an empty declaration as a target (it is not a namespace wrapper)" do
    d = discover(<<~RUBY)
      class Foo; end
      module Bar; end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Foo", is_module: false },
      { name: "Bar", is_module: true },
    ])
  end

  it "promotes every class under a namespace wrapper" do
    d = discover(<<~RUBY)
      module Admin
        class User
          def name; end
        end

        class Post
          def title; end
        end
      end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Admin::User", is_module: false },
      { name: "Admin::Post", is_module: false },
    ])
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
