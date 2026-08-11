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

  # Ruby REOPENS a class rather than redefining it, and a target's pass already
  # collects members from every reopen in the file. A second entry re-emitted the
  # whole merged set, and two declarations of one method in a single file is an
  # `RBS::DuplicatedMethodDefinitionError` — `build_instance` raises for that class,
  # poisoning the environment rather than just the file.
  it "records one target per name however many times the file reopens it" do
    d = discover(<<~RUBY)
      class ZzTwo
        def a; end
      end

      class ZzTwo
        def b; end
      end
    RUBY

    expect(d.declaration_targets).to eq([{ name: "ZzTwo", is_module: false }])
  end

  it "keeps a reopened nested class distinct from its namesake elsewhere" do
    d = discover(<<~RUBY)
      class Outer
        class Inner
          def a; end
        end
      end

      class Inner
        def b; end
      end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Outer::Inner", is_module: false },
      { name: "Inner", is_module: false }
    ])
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

  # A nested module is emitted inside its enclosing target's block and nowhere
  # else, so a wrapper hosting one is the only home it has. Dropping the
  # wrapper because "it has no members of its own" dropped `Foo` with it, and
  # the file emitted `Example22::Bar` alone.
  it "keeps a namespace wrapper that is a nested module's only home" do
    d = discover(<<~RUBY)
      class Example22
        module Foo
          def bazinga; end
        end

        class Bar
          def self.log_something; end
        end
      end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Example22", is_module: false },
      { name: "Example22::Bar", is_module: false },
    ])
  end

  # The other half of the same rule: with no target of its own the file takes
  # the single-target path, which lands on the wrapper through
  # `ClassNameExtractor` anyway. Adding it here would flatten that nesting —
  # `module ActionController; module HttpAuthentication; module Token` emits
  # nested only while the outer two stay out of the targets.
  it "still skips a wrapper whose nested module is the file's only content" do
    d = discover(<<~RUBY)
      module ActionController
        module HttpAuthentication
          module Token
            def authenticate; end
          end
        end
      end
    RUBY

    expect(d.declaration_targets).to be_empty
  end

  # A module that is itself a pure namespace has no members needing a block, so
  # it does not hold its wrapper alive.
  it "skips a wrapper whose nested module only wraps classes" do
    d = discover(<<~RUBY)
      class Holder
        module Wrapping
          class Inner
            def name; end
          end
        end

        class Bar
          def title; end
        end
      end
    RUBY

    expect(d.declaration_targets).to eq([
      { name: "Holder::Wrapping::Inner", is_module: false },
      { name: "Holder::Bar", is_module: false },
    ])
  end

  # `declarations` answers "what kind is X?" for every type the file declares —
  # wrappers and nested modules included, unlike `declaration_targets`. The
  # analyzer renders a nested target's namespace from it; resolving that kind
  # by hunting for a file named after the namespace fails whenever the file
  # isn't named after its class, and the wrapper then renders as `module`
  # against the class's own `class` block ("Declaration is duplicated").
  it "records the kind of every declaration, including wrappers and nested modules" do
    d = discover(<<~RUBY)
      class Holder
        class User
          def name; end
        end

        module Helpers
          def help; end
        end

        def self.run; end
      end

      module Admin
        class Report
          def rows; end
        end
      end
    RUBY

    expect(d.declarations).to eq({
      "Holder" => false,
      "Holder::User" => false,
      "Holder::Helpers" => true,
      "Admin" => true,
      "Admin::Report" => false,
    })
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
