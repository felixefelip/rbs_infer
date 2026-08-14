# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayImplements do
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

    expect(described_class.blocks_for(source: source))
      .to eq([{ "call" => "keep", "implements" => "::Target" }])
  end

  # Steep matches an entry by call name over the whole file, so a name written
  # twice would put BOTH entries on BOTH blocks — including on the block whose
  # target is the other one.
  it "declines a storage call written more than once in the file" do
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

    expect(described_class.blocks_for(source: source)).to eq([])
  end

  # A second block Steep would also annotate is a reason to decline even when
  # the Collector never produced a replay for it — the count has to be taken
  # the way Steep takes it.
  it "declines when an unrelated block reuses the storage call's name" do
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

    expect(described_class.blocks_for(source: source)).to eq([])
  end

  it "returns nothing for a file with no replay" do
    expect(described_class.blocks_for(source: "class Foo\n  def bar = 1\nend\n")).to eq([])
  end

  # The substring gate: no `class_eval`/`module_eval` anywhere means no parse.
  it "does not parse a file that cannot contain a replay" do
    expect(Prism).not_to receive(:parse)

    expect(described_class.blocks_for(source: "class Foo; end\n")).to eq([])
  end
end
