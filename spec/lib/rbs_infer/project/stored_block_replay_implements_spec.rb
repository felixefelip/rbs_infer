# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayImplements do
  NO_SOURCES = RbsInfer::Project::ConstantSources::NONE

  # The chain the expander recognizes: one storage method, one reader, one
  # stored block, one constant target. Same shape as `Example28`.
  def dsl(reader: "attr_reader :body")
    <<~RUBY
      module DSL
        #{reader}
        def keep(&block) = @body = block
        def apply(source) = class_eval(&source.body)
      end
    RUBY
  end

  it "names the replay target of a stored block, not its lexical owner" do
    source = dsl + <<~RUBY
      module Src
        extend DSL
        keep do
          def installed; end
        end
      end

      class Target
        extend DSL
        apply(Src)
      end
    RUBY

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES))
      .to eq([{ "call" => "keep", "in" => "::Src", "implements" => "::Target" }])
  end

  # One DSL name, two blocks, two targets. Steep matches an entry by call name
  # over the whole file, so the `in` scope is what keeps each entry on its own
  # block instead of putting both on both (felixefelip/steep#145).
  it "tells two blocks of the same storage call apart by the scope they sit in" do
    source = dsl + <<~RUBY
      module SrcA
        extend DSL
        keep { def a; end }
      end

      module SrcB
        extend DSL
        keep { def b; end }
      end

      class First
        extend DSL
        apply(SrcA)
      end

      class Second
        extend DSL
        apply(SrcB)
      end
    RUBY

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES)).to eq(
      [{ "call" => "keep", "in" => "::SrcA", "implements" => "::First" },
       { "call" => "keep", "in" => "::SrcB", "implements" => "::Second" }]
    )
  end

  # An unrelated block of the same name gets no entry of its own, and the
  # `in` scope keeps it from picking up someone else's.
  it "leaves an unrelated block reusing the storage call's name alone" do
    source = dsl + <<~RUBY
      module Src
        extend DSL
        keep { def installed; end }
      end

      class Target
        extend DSL
        apply(Src)
      end

      class Unrelated
        keep { def other; end }
      end
    RUBY

    entries = described_class.blocks_for(source: source, sources: NO_SOURCES)

    expect(entries).to eq([{ "call" => "keep", "in" => "::Src", "implements" => "::Target" }])
    expect(entries.map { |entry| entry["line"] }).not_to include(17)
  end

  it "returns nothing for a file with no replay" do
    expect(described_class.blocks_for(source: "class Foo\n  def bar = 1\nend\n", sources: NO_SOURCES)).to eq([])
  end

  # The substring gate: no `class_eval`/`module_eval` anywhere means no parse.
  it "does not parse a file that cannot contain a replay" do
    expect(Prism).not_to receive(:parse)

    expect(described_class.blocks_for(source: "class Foo; end\n", sources: NO_SOURCES)).to eq([])
  end
end
