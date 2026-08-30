# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayImplements do
  NO_SOURCES = RbsInfer::Project::ConstantSources::NONE

  # The mixin graph is the other half of the `self` answer, and these examples
  # describe one file with no project around it — so they say "nobody mixes
  # anything in" explicitly rather than leaving the seam unthreaded.
  NO_HOSTS = Object.new
  def NO_HOSTS.hosts_of(_name) = []

  # A project of exactly the constants named, as `ConstantSources` answers for
  # them — the same double the expander's own spec uses.
  def project(**declarations)
    table = declarations.to_h do |name, source|
      [name.to_s, [RbsInfer::Project::ParseCache::Entry.new(source: source, result: Prism.parse(source))]]
    end
    evals = declarations.each_value.any? { |source| source.match?(/class_eval|module_eval/) }

    Class.new do
      define_method(:parsed_for) { |name| table.fetch(name, []) }
      define_method(:eval_anywhere?) { evals }
      define_method(:inward_extend_anywhere?) { false }
      define_method(:derived) { |_entry, &derivation| derivation.call }
    end.new
  end

  # A graph that does, for the examples about the handed-out shape.
  def hosts(table)
    index = Object.new
    index.define_singleton_method(:hosts_of) { |name| table.fetch(name, []) }
    index
  end

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

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS))
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

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS)).to eq(
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

    entries = described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS)

    expect(entries).to eq([{ "call" => "keep", "in" => "::Src", "implements" => "::Target" }])
    expect(entries.map { |entry| entry["line"] }).not_to include(17)
  end

  # One entry, naming both — the annotation rides the block's single opener, so
  # every target that block reaches has to be named there. Steep takes a list
  # and checks the body against each (felixefelip/steep#149); it used to be told
  # nothing at all, and `steep check` then attributed the `def`s to the module
  # the block is written in.
  it "names every target a block is replayed onto" do
    source = dsl + <<~RUBY
      module Src
        extend DSL
        keep { def installed; end }
      end

      class First
        extend DSL
        apply(Src)
      end

      class Second
        extend DSL
        apply(Src)
      end
    RUBY

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS))
      .to eq([{ "call" => "keep", "in" => "::Src", "implements" => ["::First", "::Second"] }])
  end

  # A lone target stays a plain string — what every sidecar written before the
  # list says, and what Steep still takes.
  it "keeps a single target as a string rather than a one-element list" do
    source = dsl + <<~RUBY
      module Shared
        extend DSL
        keep { def installed; end }
      end

      module Lone
        extend DSL
        keep { def only; end }
      end

      class First
        extend DSL
        apply(Shared)
      end

      class Second
        extend DSL
        apply(Shared)
      end

      class Third
        extend DSL
        apply(Lone)
      end
    RUBY

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS))
      .to eq([{ "call" => "keep", "in" => "::Shared", "implements" => ["::First", "::Second"] },
              { "call" => "keep", "in" => "::Lone", "implements" => "::Third" }])
  end

  it "returns nothing for a file with no replay" do
    expect(described_class.blocks_for(source: "class Foo\n  def bar = 1\nend\n", sources: NO_SOURCES, mixin_index: NO_HOSTS)).to eq([])
  end

  # The substring gate: no `class_eval`/`module_eval` anywhere means no parse.
  it "does not parse a file that cannot contain a replay" do
    expect(Prism).not_to receive(:parse)

    expect(described_class.blocks_for(source: "class Foo; end\n", sources: NO_SOURCES, mixin_index: NO_HOSTS)).to eq([])
  end

  # A block replayed onto the target's SINGLETON defines `Target.age`, so the
  # annotation has to name that table — checking the body against `Target`'s
  # instances would report a method the RBS declares on the class object
  # (felixefelip/rbs_infer#267, felixefelip/steep#152).
  it "names the singleton when that is where the block's defs land" do
    source = <<~RUBY
      module DSL
        attr_reader :body
        def keep(&block) = @body = block
        def apply(source) = singleton_class.class_eval(&source.body)
      end

      module Src
        extend DSL
        keep do
          def age; 31; end
        end
      end

      class Target
        extend DSL
        apply(Src)
      end
    RUBY

    expect(described_class.blocks_for(source: source, sources: NO_SOURCES, mixin_index: NO_HOSTS))
      .to eq([{ "call" => "keep", "in" => "::Src", "implements" => "singleton(::Target)" }])
  end
  # The gate is the expander's, asked of the PROJECT. A concern writes
  # `class_methods do` and no eval at all — the eval is in the DSL, declared
  # somewhere else — so asking this file's own text skipped exactly the files
  # whose blocks needed annotating (felixefelip/rbs_infer#268).
  it "annotates a block in a file whose own text writes no eval" do
    concern = <<~RUBY
      module Source
        extend Elsewhere::DSL

        keep do
          def installed; "yes"; end
        end
      end
    RUBY
    dsl = <<~RUBY
      module Elsewhere
        module DSL
          def keep(&block)
            const_set(:Methods, Module.new).module_eval(&block)
          end
        end
      end
    RUBY

    expect(concern).not_to include("class_eval")
    expect(concern).not_to include("module_eval")

    entries = described_class.blocks_for(source: concern, sources: project("Elsewhere::DSL": dsl),
                                         mixin_index: NO_HOSTS)

    expect(entries).to eq([{ "call" => "keep", "in" => "::Source", "implements" => "::Source::Methods" }])
  end

  # A module the DSL builds and a hook HANDS to the host: the block's `def`s land
  # in the module, but they run on the host's class object, where the host's own
  # class methods live. `@implements` alone would check them against a self they
  # never have.
  context "a target the hook hands to the host" do
    def concern
      <<~RUBY
        class Module
          def include(*modules)
            modules.reverse_each do |mod|
              mod.send(:append_features, self)
              mod.send(:included, self)
            end
            self
          end
        end

        module Wrap
          module DSL
            def keep(&block)
              const_set(:Methods, Module.new).module_eval(&block)
            end

            def included(base)
              base.extend(const_get(:Methods))
            end
          end

          module Source
            extend Wrap::DSL

            keep do
              def age; 31; end
            end
          end
        end
      RUBY
    end

    it "names the host's singleton intersected with the module" do
      entries = described_class.blocks_for(source: concern, sources: NO_SOURCES,
                                           mixin_index: hosts("Wrap::Source" => ["Wrap::Host"]))

      expect(entries).to eq(
        [{ "call" => "keep", "in" => "::Wrap::Source", "implements" => "::Wrap::Source::Methods",
           "self" => "singleton(::Wrap::Host) & ::Wrap::Source::Methods" }]
      )
    end

    it "unions the hosts when the module is mixed into several" do
      entries = described_class.blocks_for(source: concern, sources: NO_SOURCES,
                                           mixin_index: hosts("Wrap::Source" => ["Wrap::One", "Wrap::Two"]))

      expect(entries.first["self"])
        .to eq("(singleton(::Wrap::One) & ::Wrap::Source::Methods) | (singleton(::Wrap::Two) & ::Wrap::Source::Methods)")
    end

    # An unmixed module's methods run with a self this pass cannot state, and
    # naming the module alone would be the wrong answer rather than a partial one.
    it "says nothing when the graph names no host" do
      entries = described_class.blocks_for(source: concern, sources: NO_SOURCES, mixin_index: NO_HOSTS)

      expect(entries.first).not_to have_key("self")
      expect(entries.first["implements"]).to eq("::Wrap::Source::Methods")
    end

    # The `class_eval`ed block keeps its old answer: `@implements` is the self
    # its bodies get at run time, and there is no host to hand anything to.
    it "leaves a replay nobody hands out without a self" do
      source = concern.sub("base.extend(const_get(:Methods))", "base.class_eval { }")

      entries = described_class.blocks_for(source: source, sources: NO_SOURCES,
                                           mixin_index: hosts("Wrap::Source" => ["Wrap::Host"]))

      expect(entries.first).not_to have_key("self")
    end
  end

  # A concern and its host are two files, and neither one alone can write the
  # entry: the concern holds the block and names no target, the host names the
  # target and holds no block. Filing entries under the file each block is
  # WRITTEN in is what lets the pair answer together
  # (felixefelip/rbs_infer#289).
  context "a block written in another file" do
    def core_include
      <<~RUBY
        class Module
          def include(*modules)
            modules.reverse_each do |mod|
              mod.send(:append_features, self)
              mod.send(:included, self)
            end
            self
          end
        end
      RUBY
    end

    def concern(name = "Fields")
      <<~RUBY
        module #{name}
          def self.included(base)
            base.class_eval do
              def installed; "yes"; end
            end
          end
        end
      RUBY
    end

    def host(name = "Filter", includes: "Fields")
      <<~RUBY
        class #{name}
          include #{includes}
        end
      RUBY
    end

    it "files the entry under the source the block is written in" do
      fields = concern
      table = described_class.blocks_by_source(source: host, sources: project(Module: core_include, Fields: fields),
                                               mixin_index: NO_HOSTS)

      expect(table.keys.map(&:object_id)).to eq([fields.object_id])
      expect(table.values.first)
        .to eq([{ "call" => "class_eval", "in" => "::Fields", "implements" => "::Filter", "method" => "included" }])
    end

    # And `blocks_for` still answers only for the file it is handed, which is
    # the host — it holds no block of its own.
    it "leaves the host's own entry list empty" do
      expect(described_class.blocks_for(source: host, sources: project(Module: core_include, Fields: concern),
                                        mixin_index: NO_HOSTS)).to eq([])
    end

    # Two hosts including one concern: one block, two classes it runs on, and
    # one entry naming both. The two halves are resolved by separate passes over
    # separate files, so only the merge sees them together.
    it "merges the entries two hosts write about one block" do
      sources = project(Module: core_include, Fields: concern)
      first = described_class.blocks_by_source(source: host("First"), sources: sources, mixin_index: NO_HOSTS)
      second = described_class.blocks_by_source(source: host("Second"), sources: sources, mixin_index: NO_HOSTS)

      merged = described_class.merge(first.values.first + second.values.first)

      expect(merged).to eq([{ "call" => "class_eval", "in" => "::Fields", "method" => "included",
                              "implements" => ["::First", "::Second"] }])
    end
  end
end
