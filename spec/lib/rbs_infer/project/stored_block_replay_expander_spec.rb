# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayExpander do
  # The seam takes `sources:` with no default, so a caller cannot forget to
  # thread it. These examples describe one file with no project behind it, so
  # they say so explicitly (docs/engineering/required-threaded-deps.md).
  def expand(source, sources: RbsInfer::Project::ConstantSources::NONE)
    described_class.expand(source, sources: sources)
  end

  it "moves a stored block into the class that replays it" do
    source = <<~RUBY
      class Wrap
        module DSL
          attr_reader :body

          def keep(&block)
            @body = block
          end

          def apply(source)
            class_eval(&source.body)
          end
        end

        module Source
          extend DSL

          keep do
            def installed
              "yes"
            end
          end
        end

        class Target
          extend DSL
          apply(Source)
        end
      end
    RUBY

    expanded = expand(source)

    # The body keeps the indentation it had in the source. Re-indenting it to
    # the reopening's column reads better and rewrites the contents of any
    # heredoc inside it, so the reopening wears the source's margin instead.
    expect(expanded).to include("class Wrap::Target\n  def installed")
    expect(expanded.scan("def installed").size).to eq(2)
    expect(Prism.parse(expanded).success?).to be(true)
  end

  # Two call sites, two targets, one block — and nothing ambiguous about it:
  # each site names the class it applies the source TO, and at runtime the block
  # runs on both. Declining this dropped the whole file, which is the shape a
  # module reused by two classes has (felixefelip/rbs_infer#263).
  it "reopens every target a stored block is replayed against" do
    source = <<~RUBY
      class Wrap
        module DSL
          attr_reader :body
          def keep(&block) = @body = block
          def apply(source) = class_eval(&source.body)
        end

        module Source
          extend DSL
          keep { def installed; end }
        end

        class First
          extend DSL
          apply(Source)
        end

        class Second
          extend DSL
          apply(Source)
        end
      end
    RUBY

    expanded = expand(source)

    expect(expanded).to include("class Wrap::First\n  def installed; end\nend")
    expect(expanded).to include("class Wrap::Second\n  def installed; end\nend")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  # What a call site genuinely cannot decide: two providers reachable from the
  # same `apply`, answering with two DIFFERENT blocks.
  it "declines a call site two providers answer with different blocks" do
    source = <<~RUBY
      class Wrap
        module DSL
          attr_reader :body
          def keep(&block) = @body = block
          def apply(source) = class_eval(&source.body)
        end

        module Other
          attr_reader :other_body
          def keep_other(&block) = @other_body = block
          def apply(source) = class_eval(&source.other_body)
        end

        module Source
          extend DSL
          extend Other
          keep { def installed; end }
          keep_other { def other_installed; end }
        end

        class Target
          extend DSL
          extend Other
          apply(Source)
        end
      end
    RUBY

    expect(expand(source)).to be_nil
  end

  it "reopens a module target as a module" do
    source = <<~RUBY
      module Wrap
        module DSL
          attr_reader :body
          def keep(&block) = @body = block
          def apply(source) = module_eval(&source.body)
        end

        module Source
          extend DSL
          keep { def installed; end }
        end

        module Target
          extend DSL
          apply(Source)
        end
      end
    RUBY

    expanded = expand(source)

    # A one-line block (`keep { … }`) has no margin of its own to reclaim, so
    # its body arrives exactly as written.
    expect(expanded).to include("module Wrap::Target\n  def installed; end")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  # `ActiveSupport::Concern`'s own direction: `included(base = nil, &block)`
  # keeps the block, `append_features(base)` replays it with
  # `base.class_eval(&@_included_block)`. `self` is the module that STORED the
  # block and the target arrives as a parameter — the mirror of the shape above,
  # and the one a real concern is written in (felixefelip/rbs_infer#247).
  context "the inward direction (`base.class_eval(&@block)`)" do
    def concern(target_body: "apply(Source)")
      <<~RUBY
        class Wrap
          module DSL
            def apply(mod)
              mod.keep(self)
            end

            def keep(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          module Source
            extend DSL

            keep do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend DSL
            #{target_body}
          end
        end
      RUBY
    end

    it "moves the block onto the target the replay was handed" do
      expanded = expand(concern)

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(expanded.scan("def installed").size).to eq(2)
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # No `attr_reader` anywhere in that source: in this direction the replaying
    # method is already inside the object holding the slot, so a reader has
    # nobody to serve. The ivar is the join instead.
    it "needs no reader to reach the stored block" do
      expect(concern).not_to include("attr_reader")
      expect(expand(concern)).not_to be_nil
    end

    # Appending expanders run over their own output, so a second pass must add
    # nothing (`SourceExpanders` requires idempotence).
    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(concern))).to be_nil
    end

    it "declines when the target never asks for the replay" do
      expect(expand(concern(target_body: ""))).to be_nil
    end

    # The forward is one hop, not a chain. A second link is another place a
    # runtime value could stand in for the constant that was resolved.
    it "declines a forward that goes through another method" do
      source = <<~RUBY
        class Wrap
          module DSL
            def apply(mod) = mod.relay(self)
            def relay(base) = base.keep(self)
            def keep(base = nil, &block)
              if base.nil? then @body = block else base.class_eval(&@body) end
            end
          end

          module Source
            extend DSL
            keep { def installed; end }
          end

          class Target
            extend DSL
            apply(Source)
          end
        end
      RUBY

      expect(expand(source)).to be_nil
    end

    # Same per-call-site rule the outward direction has: one block per site,
    # and two sites naming one source are two replays.
    it "reopens every target a stored block is replayed against" do
      source = concern.sub(/  class Target.*?\n  end\n/m, <<~RUBY)
          class First
            extend DSL
            apply(Source)
          end

          class Second
            extend DSL
            apply(Source)
          end
      RUBY

      expanded = expand(source)

      expect(expanded).to include("class Wrap::First\n  def installed")
      expect(expanded).to include("class Wrap::Second\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end
  end

  # `extend DSL` and `class Sub < Base` are the same thing to the caller: the
  # DSL method arrives with no receiver in the class body either way. Reading
  # only `extend` made a file spelling the replay through inheritance produce
  # nothing at all (felixefelip/rbs_infer#251).
  context "a DSL shared by inheritance" do
    def inherited(source_super: "Base", target_super: "Base")
      <<~RUBY
        class Wrap
          class Base
            def self.apply(mod)
              mod.keep(self)
            end

            def self.keep(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          class Source < #{source_super}
            keep do
              def installed
                "yes"
              end
            end
          end

          class Target < #{target_super}
            apply(Source)
          end
        end
      RUBY
    end

    it "moves the block onto the target, with no `extend` anywhere" do
      expanded = expand(inherited)

      expect(inherited).not_to include("extend")
      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(expanded.scan("def installed").size).to eq(2)
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # Ruby's ancestry is transitive, so this pass's has to be: `Target < Source`
    # reaches `keep` through `Source`, exactly as a direct subclass would.
    it "reaches a DSL inherited through an intermediate class" do
      expect(expand(inherited(target_super: "Source"))).to include("class Wrap::Target\n  def installed")
    end

    it "declines when the target never asks for the replay" do
      expect(expand(inherited.sub("    apply(Source)\n", ""))).to be_nil
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(inherited))).to be_nil
    end

    # Reopening a class under a different superclass is not something to reason
    # about, but walking the chain must not hang on it either.
    it "terminates on a superclass chain that loops" do
      source = inherited(source_super: "Target", target_super: "Source")

      expect { expand(source) }.not_to raise_error
    end

    # An unresolvable superclass is simply not an edge — a class inheriting from
    # something declared elsewhere still resolves its own `extend`s.
    it "ignores a superclass it cannot resolve in this file" do
      source = inherited.sub("class Source < Base", "class Source < ::Elsewhere::Base")

      expect(expand(source)).to be_nil
    end
  end

  # `apply(*modules)` forwarding inside an iteration, which is the shape the
  # generated `Module#include` pseudo-code uses. The receiver is a BLOCK
  # parameter rather than a method parameter, and the call site passes several
  # constants at once — neither was read before felixefelip/rbs_infer#253.
  context "a DSL forwarding to each of several modules" do
    def splat(sources: %w[First Second], applied: "apply(First, Second)", iteration: "reverse_each")
      kept = sources.map do |name|
        <<~RUBY
          class #{name} < Base
            keep do
              def installed_#{name.downcase}
                "#{name.downcase}"
              end
            end
          end
        RUBY
      end

      <<~RUBY
        class Wrap
          class Base
            def self.apply(*modules)
              modules.#{iteration} { |mod| mod.keep(self) }
            end

            def self.keep(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

        #{kept.join("\n").gsub(/^(?=.)/, "  ")}
          class Target < Base
            #{applied}
          end
        end
      RUBY
    end

    it "moves every named module's block onto the target" do
      expanded = expand(splat)

      expect(expanded).to include("class Wrap::Target\n  def installed_first")
      expect(expanded).to include("class Wrap::Target\n  def installed_second")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    it "resolves a single argument through the same iteration" do
      expanded = expand(splat(sources: %w[First], applied: "apply(First)"))

      expect(expanded).to include("class Wrap::Target\n  def installed_first")
      expect(expanded).not_to include("installed_second")
    end

    # The claim is about provenance, not about which yielded value is "the
    # element" — so it does not depend on knowing what the method does. Any
    # call on a handed receiver hands its block values that came from the
    # caller, including ones no first-parameter rule would survive:
    # `inject` yields the memo first, `each_with_index` an index second.
    it "does not depend on which method does the yielding" do
      %w[each map select each_with_index reverse_each each_entry tap].each do |iteration|
        expect(expand(splat(iteration: iteration)))
          .to include("class Wrap::Target\n  def installed_first"), "#{iteration} was not read"
      end
    end

    it "reads a name bound anywhere in the block's parameters" do
      source = splat.sub("{ |mod| mod.keep(self) }", "{ |index, mod| mod.keep(self) }")

      expect(expand(source)).to include("class Wrap::Target\n  def installed_first")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(splat))).to be_nil
    end

    it "declines a receiver that is neither a parameter nor bound from one" do
      source = splat.sub("modules.reverse_each { |mod| mod.keep(self) }",
                         "Registry.all.reverse_each { |mod| mod.keep(self) }")

      expect(expand(source)).to be_nil
    end

    # A destructuring target carries no name — the same reason a method's
    # would be skipped, not a rule of its own.
    it "declines a block that destructures what it is yielded" do
      source = splat.sub("{ |mod| mod.keep(self) }", "{ |(mod, _extra)| mod.keep(self) }")

      expect(expand(source)).to be_nil
    end

    it "follows a value through a nested iteration" do
      source = splat.sub("modules.reverse_each { |mod| mod.keep(self) }",
                         "modules.each { |group| group.each { |mod| mod.keep(self) } }")

      expect(expand(source)).to include("class Wrap::Target\n  def installed_first")
    end
  end

  # `x.send(:foo, a)` is statically the same call as `x.foo(a)` — the callee
  # has moved into the first argument, that is all. Reading `node.name` got
  # `send` back and left the real callee unexamined, so a DSL keeping its
  # storage method private (the reason to write `send` at all) resolved
  # nothing (felixefelip/rbs_infer#255).
  context "a replay dispatched through `send`" do
    def dispatched(call: "mod.send(:keep, self)", visibility: "private")
      <<~RUBY
        class Wrap
          module DSL
            def apply(*modules)
              modules.reverse_each { |mod| #{call} }
            end

            #{visibility}

            def keep(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          module Source
            extend DSL

            keep do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend DSL
            apply(Source)
          end
        end
      RUBY
    end

    it "reads through `send` to the method it dispatches" do
      expanded = expand(dispatched)

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    it "reads `public_send` and `__send__` the same way" do
      ["mod.public_send(:keep, self)", "mod.__send__(:keep, self)"].each do |call|
        expect(expand(dispatched(call: call)))
          .to include("class Wrap::Target\n  def installed"), "#{call} was not read"
      end
    end

    it "reads a string name as well as a symbol" do
      expect(expand(dispatched(call: 'mod.send("keep", self)')))
        .to include("class Wrap::Target\n  def installed")
    end

    # Visibility is not something this pass reads — `send` is what hid the
    # call, not `private`. The public spelling resolves identically.
    it "does not depend on the method being private" do
      expect(expand(dispatched(visibility: "public")))
        .to include("class Wrap::Target\n  def installed")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(dispatched))).to be_nil
    end

    # A computed name is the arbitrary-dispatch case: which method runs is a
    # runtime answer, and guessing is what this pass exists not to do.
    it "declines a `send` whose method name is computed" do
      expect(expand(dispatched(call: "mod.send(hook_name, self)"))).to be_nil
    end

    it "declines a `send` that hands over something other than self" do
      expect(expand(dispatched(call: "mod.send(:keep, Registry.default)"))).to be_nil
    end

    # The replay half reads the same way: `base.send(:class_eval, &@body)` is
    # `base.class_eval(&@body)`.
    it "reads a `class_eval` dispatched through `send`" do
      source = dispatched.sub("base.class_eval(&@body)", "base.send(:class_eval, &@body)")

      expect(expand(source)).to include("class Wrap::Target\n  def installed")
    end
  end

  context "a DSL method that delegates to an object it holds" do
    def delegated(kept: "keep", memo: "@holder ||= Holder.new", call: "@holder.#{kept}(base, &block)")
      <<~RUBY
        class Wrap
          module DSL
            def apply(*modules)
              modules.reverse_each { |mod| mod.send(:keep, self) }
            end

            private

            def keep(base = nil, &block)
              #{memo}
              #{call}
            end
          end

          class Holder
            def #{kept}(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          module Source
            extend DSL

            keep do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend DSL
            apply(Source)
          end
        end
      RUBY
    end

    it "follows the delegation to the object that keeps the block" do
      expanded = expand(delegated)

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # The name the SOURCE writes is the delegating method's, never the held
    # object's. Reading the keeper's name works only while the two are spelled
    # alike, and renaming the held method changes nothing about the program.
    it "does not depend on the two methods sharing a name" do
      expect(expand(delegated(kept: "keep_or_replay")))
        .to include("class Wrap::Target\n  def installed")
    end

    it "reads a plain assignment as well as a memoization" do
      expect(expand(delegated(memo: "@holder = Holder.new")))
        .to include("class Wrap::Target\n  def installed")
    end

    it "resolves the held class through the enclosing namespace" do
      expect(expand(delegated(memo: "@holder ||= Wrap::Holder.new")))
        .to include("class Wrap::Target\n  def installed")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(delegated))).to be_nil
    end

    # Forwarding the block is the whole claim: without it the storage on the
    # other side keeps nothing, so the call is not the pass-through it looks like.
    it "declines a delegation that drops the block" do
      expect(expand(delegated(call: "@holder.keep(base)"))).to be_nil
    end

    it "declines a delegation to an object built somewhere else" do
      expect(expand(delegated(memo: "@holder ||= registry.fetch(:holder)"))).to be_nil
    end

    it "declines a held class this file does not declare" do
      expect(expand(delegated(memo: "@holder ||= External::Holder.new"))).to be_nil
    end

    # Two constructions under one name say nothing decidable about which object
    # the block reached, and declaration order must not decide it.
    it "declines an ivar filled with two different classes" do
      source = delegated(memo: "@holder ||= Holder.new\n              @holder = Other.new")

      expect(expand(source)).to be_nil
    end
  end

  # `ActiveSupport::Concern`'s real shape: the applier is `Module#include`, a
  # method of a class the project reopens, and it reaches for a method the
  # ARGUMENT owns. Three things had to give at once — the file boundary, the
  # core reopening as a provider, and the two halves sharing an owner
  # (felixefelip/rbs_infer#256).
  context "a DSL whose applier is declared elsewhere" do
    # A project of exactly the constants named, as `ConstantSources` answers
    # for them. The lookup itself is `ConstantSources`' own spec; here the
    # question is only what the join does once the roots arrive.
    # `eval_anywhere?` is asked of the PROJECT, so the double answers from the
    # declarations it was built with — which is what the real `ConstantSources`
    # computes by scanning the corpus.
    def project(**declarations)
      table = declarations.to_h do |name, source|
        [name.to_s, [RbsInfer::Project::ParseCache::Entry.new(source: source, result: Prism.parse(source))]]
      end
      evals = declarations.each_value.any? { |source| source.match?(/class_eval|module_eval/) }
      extends = declarations.each_value.any? { |source| source.include?(".extend") }

      Class.new do
        define_method(:parsed_for) { |name| table.fetch(name, []) }
        define_method(:eval_anywhere?) { evals }
        define_method(:inward_extend_anywhere?) { extends }
        # The real one memoizes; a double only has to answer.
        define_method(:derived) { |_entry, &derivation| derivation.call }
      end.new
    end

    def core_applier(name: "Module")
      <<~RUBY
        class #{name}
          def banana(*modules)
            modules.reverse_each { |mod| mod.send(:bananed, self) }
          end
        end
      RUBY
    end

    def concern(applied: "banana(Source)")
      <<~RUBY
        module Wrap
          module DSL
            private

            def bananed(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          module Source
            extend DSL

            bananed do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend DSL
            #{applied}
          end
        end
      RUBY
    end

    it "reads an applier reopened on `Module` in another file" do
      expanded = expand(concern, sources: project(Module: core_applier))

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # The file alone says nothing about where `banana` comes from, and guessing
    # is what this pass exists not to do.
    it "declines the same file when the project has no such reopening" do
      expect(expand(concern)).to be_nil
    end

    it "reads a `Class` reopening for a class body" do
      expect(expand(concern, sources: project(Class: core_applier(name: "Class"))))
        .to include("class Wrap::Target\n  def installed")
    end

    # `Class`'s instance methods are not in a MODULE's body, so a module target
    # cannot have been the one calling it.
    it "does not offer `Class` to a module body" do
      source = concern.sub("class Target", "module Target")

      expect(expand(source, sources: project(Class: core_applier(name: "Class")))).to be_nil
    end

    it "reads an applier from a module this file extends but does not declare" do
      source = concern(applied: "banana(Source)").sub("class Target\n    extend DSL",
                                                      "class Target\n    extend ::Elsewhere::Applier")
      declared = <<~RUBY
        module Elsewhere
          module Applier
            def banana(*modules)
              modules.reverse_each { |mod| mod.send(:bananed, self) }
            end
          end
        end
      RUBY

      expect(expand(source, sources: project("Elsewhere::Applier": declared)))
        .to include("class Wrap::Target\n  def installed")
    end

    # A file with NO trace of the DSL is examined all the same, once the project
    # writes an eval somewhere. It has to be: a concern writes its `class_eval`
    # in its own file and the host writes only `include`, so the file the block
    # must be moved INTO is precisely the one that never says `class_eval`
    # (felixefelip/rbs_infer#265).
    it "examines a file whose DSL leaves no trace in it" do
      source = <<~RUBY
        module Wrap
          class Target
            banana(Source)
          end
        end
      RUBY

      expect(source).not_to include("class_eval")

      # The shape the fix is about: the block is written in the SOURCE's own
      # file, inside the hook the applier forwards to, and the host file says
      # only `banana(Source)`.
      declared = <<~RUBY
        module Source
          def self.bananed(base)
            base.class_eval do
              def installed; end
            end
          end
        end
      RUBY

      expect(expand(source, sources: project(Module: core_applier, Source: declared)))
        .to include("class Wrap::Target\n  def installed")
    end

    # What the gate still buys: a project that writes no eval anywhere can hold
    # no replay anywhere, so the pass costs it one memoized answer and never
    # parses a thing.
    it "does not examine any file when the project writes no eval at all" do
      source = <<~RUBY
        module Wrap
          class Target
            banana(Source)
          end
        end
      RUBY

      sources = project(Module: "class Module\nend\n")

      expect(Prism).not_to receive(:parse)
      expect(expand(source, sources: sources)).to be_nil
    end

    # An `apply` written in the OTHER file names a target this rewrite cannot
    # reach — only the shapes are absorbed, never the call sites.
    it "ignores a replay whose call sites are in the other file" do
      elsewhere = core_applier + <<~RUBY
        module Other
          module Src
            extend Wrap::DSL
            bananed { def elsewhere_only; end }
          end

          class Dst
            extend Wrap::DSL
            banana(Src)
          end
        end
      RUBY

      expanded = expand(concern, sources: project(Module: elsewhere))

      expect(expanded).not_to include("elsewhere_only")
      expect(expanded).to include("class Wrap::Target\n  def installed")
    end

    it "adds nothing on a second pass over its own output" do
      sources = project(Module: core_applier)

      expect(expand(expand(concern, sources: sources), sources: sources)).to be_nil
    end

    # `class Object; def banana` makes the applier callable in every class body
    # exactly as `class Module` does, which is the reason the chain is derived
    # rather than listed — a hand-written `%w[Module Class]` stops here.
    it "reads an applier reopened further up the chain" do
      expect(expand(concern, sources: project(Object: core_applier(name: "Object"))))
        .to include("class Wrap::Target\n  def installed")
    end

    describe "the chain it consults" do
      let(:chains) { RbsInfer::Project::StoredBlockReplayExpander::Collector::CORE_SELF_CHAINS }

      it "is what `self` in each kind of body actually inherits from" do
        expect(chains).to eq("class" => %w[Class Module Object BasicObject],
                             "module" => %w[Module Object BasicObject])
      end

      # `ancestors` would answer this too, and would also answer whatever the
      # ANALYZER's own gems injected into `Object` (`PP::ObjectMixin`,
      # `JSON::GeneratorMethods`) — no fact about the project being read, and
      # different from one environment to the next.
      it "carries no module injected into the live process" do
        expect(chains.values.flatten).to all(satisfy { |name| Object.const_get(name).is_a?(Class) })
      end
    end
  end

  # The half of #256 that needs no other file: the applier and the keeper are
  # written in one source but owned by different modules, joined only through
  # the argument. Reading the callee off the forward's own owner missed it.
  context "an applier and a keeper in different modules" do
    def split(applier_body: "modules.reverse_each { |mod| mod.send(:bananed, self) }")
      <<~RUBY
        module Wrap
          module Applier
            def banana(*modules)
              #{applier_body}
            end
          end

          module Keeper
            def bananed(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          module Source
            extend Keeper

            bananed do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend Applier

            banana(Source)
          end
        end
      RUBY
    end

    it "resolves the forwarded callee against the argument's provider" do
      expanded = expand(split)

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # `Target` never extends `Keeper`, so nothing about the target says where
    # the block is; only the argument does.
    it "needs no shared provider between the target and the source" do
      expect(split).to include("extend Applier")
      expect(split).not_to include("Target\n      extend Keeper")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(split))).to be_nil
    end

    it "declines when the argument's provider keeps nothing under that name" do
      expect(expand(split(applier_body: "modules.reverse_each { |mod| mod.send(:absent, self) }"))).to be_nil
    end
  end

  # `Module#include` is written this way — `append_features` first, then the
  # `included` notification — so an applier handing its argument two messages is
  # the shape a plain `include X` has, not an exotic one
  # (felixefelip/rbs_infer#259).
  context "an applier that hands its argument more than one message" do
    def notes_nothing
      <<~BODY
        def noted(base)
          nil
        end
      BODY
    end

    def notes_a_block
      <<~BODY
        def noted(base = nil, &block)
          if base.nil?
            @other = block
          else
            base.class_eval(&@other) if @other
          end
        end
      BODY
    end

    def two(noted: notes_nothing)
      <<~RUBY
        module Wrap
          module DSL
            def banana(*modules)
              modules.reverse_each do |mod|
                mod.send(:noted, self)
                mod.send(:bananed, self)
              end
            end

            def bananed(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end

            #{noted.gsub("\n", "\n    ").rstrip}
          end

          module Source
            extend DSL

            bananed do
              def installed
                "yes"
              end
            end
          end

          class Target
            extend DSL

            banana(Source)
          end
        end
      RUBY
    end

    it "reads the forward that reaches a replay" do
      expanded = expand(two)

      expect(expanded).to include("class Wrap::Target\n  def installed")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # The other message is a real forward by every syntactic measure — same
    # receiver, same lone `self` argument. What separates them is that `noted`
    # keeps nothing, and only the join can see that.
    it "is not told apart by the call shape" do
      expect(two).to include("mod.send(:noted, self)")
      expect(two).to include("def noted(base)")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(two))).to be_nil
    end

    # Two forwards BOTH reaching a replay is the ambiguity the count was meant
    # to catch, and it still declines — the block a target asks for cannot be
    # decided by which `def` came first.
    it "declines when two of them reach a replay" do
      source = two(noted: notes_a_block)

      expect(Prism.parse(source).success?).to be(true)
      expect(expand(source)).to be_nil
    end
  end

  # Ruby's own `included` hook with no DSL wrapped around it: the block is
  # written where it runs instead of being kept for later, so there is no
  # storage step to look it up through (felixefelip/rbs_infer#260).
  context "a replay whose block is written in the hook itself" do
    def hook(name: "included", applied: "include(Hookable)")
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

        class Host
          module Hookable
            def self.#{name}(base)
              base.class_eval do
                def from_hook
                  "hook"
                end
              end
            end
          end

          #{applied}
        end
      RUBY
    end

    it "moves the block onto the class that includes the hook" do
      expanded = expand(hook)

      expect(expanded).to include("class Host\n  def from_hook")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    it "keeps the block where it was written, with nothing stored anywhere" do
      expect(hook).not_to include("&block")
      expect(hook).not_to include("@")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(hook))).to be_nil
    end

    # The `include` is the only thing that says who `base` is. Ruby calls no
    # hook named `after_included`, so nothing does.
    it "declines a hook under a name nothing calls" do
      expect(expand(hook(name: "after_included"))).to be_nil
    end

    it "declines when nothing includes the module" do
      expect(expand(hook(applied: "# nothing"))).to be_nil
    end

    # `def self.included` is reached by Hookable and by nothing else. Recording
    # it as an instance method would offer it to whoever extends the module,
    # which is a different table entirely.
    it "does not offer the hook to a module that extends it" do
      source = hook(applied: "# nothing").sub("class Host", <<~EXTENDER)
        class Extender
          extend Host::Hookable
        end

        class Host
      EXTENDER

      expect(expand(source)).to be_nil
    end
  end


  # The DSL that runs the block it was just handed, with nothing stored: both
  # other outward shapes fetch their block from a slot, so an immediate
  # `class_eval(&block)` was no shape at all — the plainest spelling there is
  # (felixefelip/rbs_infer#268).
  context "a DSL that evaluates the block it was handed" do
    def immediate(runs: "class_eval(&block)", declares: "", applied: "bazinga do\n      def age; 31; end\n    end")
      <<~RUBY
        class Wrap
          module DSL
            def bazinga(&block)
              #{runs}
            end
          end

          class Target
            extend Wrap::DSL

            #{declares}
            #{applied}
          end
        end
      RUBY
    end

    it "runs it on the class whose body wrote the call" do
      expanded = expand(immediate)

      expect(expanded).to include("class Wrap::Target\n  def age; 31; end")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    it "runs it on that class's singleton when the DSL takes the hop" do
      expanded = expand(immediate(runs: "singleton_class.class_eval(&block)"))

      expect(expanded).to include("class Wrap::Target\n  class << self\n    def age; 31; end")
    end

    # `self` inside the DSL is the subject, so `const_get` reads ITS constants —
    # the shape `ActiveSupport::Concern#class_methods` is written in.
    it "runs it on a module the DSL fetches by name" do
      expanded = expand(immediate(runs: "const_get(:Methods).module_eval(&block)", declares: "module Methods; end\n"))

      expect(expanded).to include("module Wrap::Target::Methods\n  def age; 31; end")
    end

    # Written as syntax it means what it means where the DSL is written, which
    # is not where the call site is.
    it "runs it on a module the DSL names outright" do
      source = immediate(runs: "Written.module_eval(&block)").sub("module DSL", "module Written; end\n\n  module DSL")

      expect(expand(source)).to include("module Wrap::Written\n  def age; 31; end")
    end

    it "declines a name the project declares nothing for" do
      expect(expand(immediate(runs: "const_get(:Missing).module_eval(&block)"))).to be_nil
    end

    # An object this pass cannot name is one it will not relocate a block onto.
    it "declines a receiver that names neither our own self nor a constant" do
      expect(expand(immediate(runs: "@holder.class_eval(&block)"))).to be_nil
      expect(expand(immediate(runs: "other.class_eval(&block)"))).to be_nil
    end

    it "declines when the DSL evaluates the block onto two different targets" do
      source = immediate(declares: "module A; end\n    module B; end\n")
               .sub("class_eval(&block)\n", "const_get(:A).module_eval(&block)\n              const_get(:B).module_eval(&block)\n")

      expect(expand(source)).to be_nil
    end

    it "declines when nothing calls the DSL" do
      expect(expand(immediate(applied: "# nothing"))).to be_nil
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(immediate))).to be_nil
    end

    # A local is where you put a value you are about to use — `ActiveSupport`
    # writes the module to one before evaluating into it — not an object this
    # pass cannot name.
    context "with the target held in a local" do
      def held(binds, declares: "module Methods; end\n")
        immediate(runs: "#{binds}\n              mod.module_eval(&block)", declares: declares)
      end

      it "reads a local bound to a fetched constant" do
        expect(expand(held("mod = const_get(:Methods)")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      it "reads a local bound to a written constant" do
        source = held("mod = Written", declares: "").sub("module DSL", "module Written; end\n\n  module DSL")

        expect(expand(source)).to include("module Wrap::Written\n  def age; 31; end")
      end

      # The two spellings of filling it conditionally are one claim, so both are
      # read: a ternary is one assignment holding a conditional, an if/else is
      # two assignments.
      it "reads a ternary whose arms name the same module" do
        expect(expand(held("mod = flag? ? const_get(:Methods) : const_get(:Methods)")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      it "reads an if/else whose arms name the same module" do
        expect(expand(held("if flag?\n                mod = const_get(:Methods)\n              else\n                mod = const_get(:Methods)\n              end")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      # The two spellings resolve in different places — one under the caller's
      # `self`, one where the DSL is written — so agreeing on the LETTERS is not
      # agreeing on the module.
      it "declines arms that name it two different ways" do
        source = held("mod = flag? ? const_get(:Methods) : Wrap::Target::Methods")

        expect(expand(source)).to be_nil
      end

      it "declines arms that name different modules" do
        source = held("mod = flag? ? const_get(:Methods) : const_get(:Other)",
                      declares: "module Methods; end\n    module Other; end\n")

        expect(expand(source)).to be_nil
      end

      # A path where the local holds nothing is a path where `mod.module_eval`
      # raises, so it names no other module — the same reading the rest of the
      # pass gives a guard. Both spellings of it, since they are the same Ruby.
      it "reads past a path that leaves the local empty" do
        expect(expand(held("mod = const_get(:Methods) if flag?")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
        expect(expand(held("mod = flag? ? const_get(:Methods) : nil")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      # An arm that is some other expression may well be a module, and one this
      # pass failed to name.
      it "declines an arm it cannot name" do
        expect(expand(held("mod = flag? ? const_get(:Methods) : fetch_it"))).to be_nil
      end

      # Which module a parameter holds comes from the call site, and that is the
      # `apply` shape rather than this one.
      it "declines a local the body never fills" do
        source = immediate(runs: "mod.module_eval(&block)").sub("bazinga(&block)", "bazinga(mod, &block)")

        expect(expand(source)).to be_nil
      end
    end

    # A module the DSL BUILDS, which is what `ActiveSupport::Concern` does:
    # `const_defined?(:ClassMethods) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)`.
    # Being undeclared is the normal state of one — the reopening this pass emits
    # is what declares it.
    context "with a module the DSL creates" do
      it "runs the block on a module `const_set` builds" do
        expect(expand(immediate(runs: "const_set(:Methods, Module.new).module_eval(&block)")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      it "takes the keyword from the constructor" do
        expect(expand(immediate(runs: "const_set(:Methods, Class.new).class_eval(&block)")))
          .to include("class Wrap::Target::Methods\n  def age; 31; end")
      end

      # The Concern spelling: fetch it if it is there, build it if it is not.
      # One claim written as two paths, and the module is there afterwards
      # either way.
      it "reads the fetch-or-build ternary as one answer" do
        expect(expand(immediate(runs: "mod = const_defined?(:Methods) ? const_get(:Methods) : const_set(:Methods, Module.new)\n              mod.module_eval(&block)")))
          .to include("module Wrap::Target::Methods\n  def age; 31; end")
      end

      # It names Methods, but says nothing about what Methods is, and a block
      # cannot be relocated onto a type this pass cannot write down.
      it "declines a `const_set` of something that is not a fresh namespace" do
        expect(expand(immediate(runs: "const_set(:Methods, whatever).module_eval(&block)"))).to be_nil
      end

      it "adds nothing on a second pass over its own output" do
        source = immediate(runs: "const_set(:Methods, Module.new).module_eval(&block)")

        expect(expand(expand(source))).to be_nil
      end
    end

    # The storage path is untouched: a DSL that keeps the block for later is
    # still read as storage, and one that does both does both.
    it "still reads a DSL that keeps the block instead of running it" do
      source = immediate.sub("class_eval(&block)", "@body = block")

      expect(expand(source)).to be_nil
    end
  end

  # The hook's OTHER effect: `base.extend(M)` puts a module in the target's
  # singleton, with no block moved anywhere. It is what makes a concern's
  # `ClassMethods` the host's class methods, and the transcribed
  # `ActiveSupport::Concern#append_features` has been writing exactly this line
  # since felixefelip/rbs_infer#262 with nothing reading it
  # (felixefelip/rbs_infer#268).
  context "an `extend` the hook puts on the target" do
    def hook(extended: "const_get(:BananaMethods)",
             declares: "module BananaMethods; def age; 31; end; end",
             applied: "include(Host::Hookable)")
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

        class Host
          module Applier
            def included(base)
              base.extend(#{extended})
            end
          end

          module Hookable
            extend Host::Applier

            #{declares}
          end

          class Target
            #{applied}
          end
        end
      RUBY
    end

    # `self` inside the hook is the module being included — that is the object
    # the call was dispatched on — so `const_get` reads ITS constants, not the
    # applier's.
    it "extends the target with the module the hook fetches by name" do
      expanded = expand(hook)

      expect(expanded).to include("class Host::Target\n  extend Host::Hookable::BananaMethods\nend")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # Written as syntax, it means what it means where it is WRITTEN: the
    # applier's lexical scope, which is not the module being included.
    it "extends it with a module the hook names outright" do
      source = hook(extended: "Written", declares: "# nothing").sub(
        "def included(base)", "module Written; def age; 31; end; end\n\n    def included(base)"
      )

      expect(expand(source)).to include("class Host::Target\n  extend Host::Applier::Written\nend")
    end

    it "extends every class that includes the hook" do
      expanded = expand(hook.sub("class Target", "class Other\n    include(Host::Hookable)\n  end\n\n  class Target"))

      expect(expanded).to include("class Host::Other\n  extend Host::Hookable::BananaMethods\nend")
      expect(expanded).to include("class Host::Target\n  extend Host::Hookable::BananaMethods\nend")
    end

    it "reads every module one hook extends the target with" do
      expanded = expand(
        hook(extended: "const_get(:BananaMethods)",
             declares: "module BananaMethods; end\n    module OtherMethods; end")
          .sub("base.extend(const_get(:BananaMethods))",
               "base.extend(const_get(:BananaMethods))\n      base.extend(const_get(:OtherMethods))")
      )

      expect(expanded).to include("extend Host::Hookable::BananaMethods")
      expect(expanded).to include("extend Host::Hookable::OtherMethods")
    end

    # What `if const_defined?(:ClassMethods)` says, answered by the project
    # rather than by reading the condition: a concern that declares no such
    # module is extended with nothing, and emitting the line would name a type
    # nothing declares.
    it "declines a name the project declares nothing for" do
      expect(expand(hook(declares: "# nothing"))).to be_nil
    end

    # `extend` takes a module. A class of that name is not the thing being
    # asked about, and reopening the target with it would not even run.
    it "declines a class of that name" do
      expect(expand(hook(declares: "class BananaMethods; end"))).to be_nil
    end

    # Which constant an interpolated name reaches is a runtime answer — the
    # same line felixefelip/rbs_infer#268 draws around `const_set`.
    it "declines a name the source computes" do
      expect(expand(hook(extended: 'const_get(:"\#{prefix}Methods")'))).to be_nil
    end

    # The parameter is the whole provenance claim: it is the object the caller
    # handed us, and nothing says what any other receiver is.
    it "declines an extend written on something else" do
      expect(expand(hook.sub("base.extend", "Object.extend"))).to be_nil
    end

    it "declines when nothing includes the module" do
      expect(expand(hook(applied: "# nothing"))).to be_nil
    end

    # Two modules answering `included` for one include is one runtime dispatch,
    # and which of them wins is not something the source says.
    it "declines when two appliers answer the same hook" do
      source = hook(declares: "module BananaMethods; end\n    module OtherMethods; end")
               .sub("module Hookable\n", "module Other\n    def included(base)\n      base.extend(const_get(:OtherMethods))\n    end\n  end\n\n  module Hookable\n")
               .sub("extend Host::Applier", "extend Host::Applier\n    extend Host::Other")

      expect(expand(source)).to be_nil
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(hook))).to be_nil
    end
  end

  # A `def self.` DSL is reached through the singleton, so it answers for the
  # module itself and for its subclasses — never for a module that `extend`s it,
  # whose calls land in the instance table instead.
  context "the table a `def self.` DSL is found in" do
    def singleton_dsl(relation: "class Target < Wrap::Base")
      <<~RUBY
        class Wrap
          class Base
            def self.apply(mod)
              mod.keep(self)
            end

            def self.keep(base = nil, &block)
              if base.nil?
                @body = block
              else
                base.class_eval(&@body) if @body
              end
            end
          end

          class Source < Base
            keep do
              def installed
                "yes"
              end
            end
          end
        end

        #{relation}
          apply(Wrap::Source)
        end
      RUBY
    end

    it "answers for a subclass" do
      expect(expand(singleton_dsl)).to include("class Target\n  def installed")
    end

    it "declines for a module that extends it instead" do
      expect(expand(singleton_dsl(relation: "class Target\n  extend Wrap::Base"))).to be_nil
    end
  end
  # `base.singleton_class.class_eval(&@block)` — the same relocation onto the
  # same class, landing in the other method table. It is what a DSL spelling
  # `class_methods do` is written to do, and reading only the bare parameter as
  # a target made it no shape at all (felixefelip/rbs_infer#267).
  context "a replay onto the target's singleton" do
    def concern(receiver: "base.singleton_class")
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

        class Wrap
          module DSL
            def keep(&block)
              @body = block
            end

            def included(base)
              #{receiver}.class_eval(&@body) if @body
            end
          end

          module Source
            extend DSL

            keep do
              def age
                31
              end
            end
          end

          class Target
            include(Wrap::Source)
          end
        end
      RUBY
    end

    it "reopens the target's singleton, not the target" do
      expanded = expand(concern)

      expect(expanded).to include("class Wrap::Target
  class << self
    def age")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # The same file with the hop removed. Both spellings resolve; what changes
    # is which table the `def` is emitted in, so the pair is what says the
    # singleton answer is read off the receiver rather than assumed.
    it "reopens the target itself when the hop is not written" do
      expanded = expand(concern(receiver: "base"))

      expect(expanded).to include("class Wrap::Target
  def age")
      expect(expanded).not_to include("class << self")
    end

    it "adds nothing on a second pass over its own output" do
      expect(expand(expand(concern))).to be_nil
    end

    # `singleton_class` takes no arguments, so a same-named method that does is
    # somebody else's and says nothing about a method table.
    it "declines a `singleton_class` call that is not Ruby's" do
      expect(expand(concern(receiver: "base.singleton_class(:eager)"))).to be_nil
    end

    # The hop is only safe because the object it starts from is the one we were
    # handed. `Other.singleton_class` is a class this pass never resolved.
    it "declines a singleton hop off something not handed to the method" do
      expect(expand(concern(receiver: "Wrap::Other.singleton_class"))).to be_nil
    end
  end

  # The outward direction of the same question: the DSL replays onto its own
  # `self` rather than onto something passed in, and `singleton_class` there
  # names the applying class's own class object.
  context "a replay onto the applier's own singleton" do
    def outward(receiver: "singleton_class.")
      <<~RUBY
        class Wrap
          module DSL
            attr_reader :body

            def keep(&block)
              @body = block
            end

            def apply(source)
              #{receiver}class_eval(&source.body)
            end
          end

          module Source
            extend DSL

            keep do
              def age
                31
              end
            end
          end

          class Target
            extend DSL
            apply(Source)
          end
        end
      RUBY
    end

    it "reopens the applier's singleton" do
      expect(expand(outward)).to include("class Wrap::Target
  class << self
    def age")
    end

    it "reopens the applier itself when the hop is not written" do
      expect(expand(outward(receiver: ""))).not_to include("class << self")
    end

    # The rewrite emits a reopening of the class whose body wrote `apply`, so a
    # replay running on some other object is an answer about the wrong class.
    it "declines a replay written on something other than the applier" do
      expect(expand(outward(receiver: "Wrap::Other."))).to be_nil
    end
  end
end
