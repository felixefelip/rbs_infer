# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# Ruby draws no line between `module X; end` and a constant filled with a fresh
# module — the second even takes the constant's name. The pipeline drew one, so
# `X = Module.new` came out as a member (`X: Module`) and `const_set` as nothing
# (felixefelip/rbs_infer#268).
RSpec.describe RbsInfer::Project::ConstantDeclarationExpander do
  def expand(source)
    described_class.expand(source)
  end

  it "reads a constant assigned a fresh module as a module declaration" do
    expanded = expand(<<~RUBY)
      module Wrap
        Banana = Module.new
      end
    RUBY

    expect(expanded).to eq(<<~RUBY)
      module Wrap
        module Banana
        end
      end
    RUBY
  end

  # The same declaration with the name written as data. `const_set` is a call,
  # so nothing about it looked like a declaration at all.
  it "reads `const_set` with a literal name the same way" do
    expanded = expand(<<~RUBY)
      module Wrap
        const_set(:Banana, Module.new)
      end
    RUBY

    expect(expanded).to include("module Banana\n  end")
  end

  it "reads it through an explicit `self` receiver too" do
    expect(expand("module Wrap\n  self.const_set(\"Banana\", Module.new)\nend\n"))
      .to include("module Banana")
  end

  # `Erro = Class.new(StandardError)` is the shape half the gems in a Gemfile
  # use to declare an error class.
  it "carries a superclass over" do
    expect(expand("class Wrap\n  Erro = Class.new(StandardError)\nend\n"))
      .to include("class Erro < StandardError\n  end")
  end

  # A block passed to `Class.new` is `module_eval`ed against the new class, so
  # its body IS the class body — the same operation `ClassEvalExpander` reads
  # for a reopening.
  it "moves a constructor block's body into the declaration" do
    expanded = expand(<<~RUBY)
      class Wrap
        Bag = Class.new do
          def size
            1
          end
        end
      end
    RUBY

    expect(expanded).to eq(<<~RUBY)
      class Wrap
        class Bag
          def size
            1
          end
        end
      end
    RUBY
  end

  # The one shape that needs more than a single pass. The inner constant is
  # inside a BLOCK while the outer one is still a constructor call, so nothing
  # collects it; once the outer is a real class body it is an ordinary
  # statement. Stopping after one pass would leave the file half-desugared —
  # and would break the seam's contract, since applying the expander to its own
  # output would change it again (`SourceExpanders`).
  it "desugars a constructor nested in a constructor" do
    expanded = expand(<<~RUBY)
      class Wrap
        Outer = Class.new do
          Inner = Module.new
        end
      end
    RUBY

    expect(expanded).to eq(<<~RUBY)
      class Wrap
        class Outer
          module Inner
          end
        end
      end
    RUBY
  end

  it "adds nothing on a second pass over its own output" do
    source = "module Wrap\n  Banana = Module.new\nend\n"

    expect(expand(expand(source))).to be_nil
  end

  # The whole reason the rewrite may happen in place: a call in a class body
  # sits where a declaration may sit. Inside a method it does not — and which
  # object `self` is when that method RUNS is a different question, the one
  # Rails' own `class_methods` asks.
  it "declines a `const_set` written in a method body" do
    expect(expand("class Wrap\n  def build\n    const_set(:Late, Module.new)\n  end\nend\n")).to be_nil
  end

  it "declines a `const_set` on another object" do
    expect(expand("class Wrap\n  Other.const_set(:Banana, Module.new)\nend\n")).to be_nil
  end

  # A computed name is what the constant is called at RUNTIME, which no rewrite
  # can read.
  it "declines a computed name" do
    expect(expand('class Wrap
  const_set(:"#{prefix}Methods", Module.new)
end
')).to be_nil
  end

  # `Struct.new` and `Data.define` answer with a fresh class too, and they
  # declare MEMBERS with it — emitting a bare `class Point` would be a class
  # whose accessors are missing, which is worse than emitting nothing.
  it "declines a constructor it does not know" do
    expect(expand("class Wrap\n  Point = Struct.new(:x)\nend\n")).to be_nil
  end

  # `Class.new(base)` names a class the source does not say.
  it "declines a superclass that is not a constant" do
    expect(expand("class Wrap\n  Sub = Class.new(base)\nend\n")).to be_nil
  end

  # The block binds the new module to a name the body reads it under, and that
  # name does not survive becoming a module body.
  it "declines a constructor block that takes the module as a parameter" do
    expect(expand("class Wrap\n  M = Module.new { |mod| mod.name }\nend\n")).to be_nil
  end

  # A constant in a singleton class body belongs to `Wrap.singleton_class`,
  # which is not a name a declaration can be emitted under.
  it "declines a constant written in a `class << self` body" do
    expect(expand("class Wrap\n  class << self\n    Banana = Module.new\n  end\nend\n")).to be_nil
  end

  it "does not parse a file that cannot contain one" do
    expect(Prism).not_to receive(:parse)

    expect(expand("class Wrap\n  BANANA = 1\nend\n")).to be_nil
  end
end
