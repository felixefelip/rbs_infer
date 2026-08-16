# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::StoredBlockReplayExpander do
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

    expanded = described_class.expand(source)

    # The body keeps the indentation it had in the source. Re-indenting it to
    # the reopening's column reads better and rewrites the contents of any
    # heredoc inside it, so the reopening wears the source's margin instead.
    expect(expanded).to include("class Wrap::Target\n      def installed")
    expect(expanded.scan("def installed").size).to eq(2)
    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "declines a stored block replayed against more than one target" do
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

    expect(described_class.expand(source)).to be_nil
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

    expanded = described_class.expand(source)

    # A one-line block (`keep { … }`) has no margin of its own to reclaim, so
    # its body arrives exactly as written.
    expect(expanded).to include("module Wrap::Target\ndef installed; end")
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
      expanded = described_class.expand(concern)

      expect(expanded).to include("class Wrap::Target\n      def installed")
      expect(expanded.scan("def installed").size).to eq(2)
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # No `attr_reader` anywhere in that source: in this direction the replaying
    # method is already inside the object holding the slot, so a reader has
    # nobody to serve. The ivar is the join instead.
    it "needs no reader to reach the stored block" do
      expect(concern).not_to include("attr_reader")
      expect(described_class.expand(concern)).not_to be_nil
    end

    # Appending expanders run over their own output, so a second pass must add
    # nothing (`SourceExpanders` requires idempotence).
    it "adds nothing on a second pass over its own output" do
      expect(described_class.expand(described_class.expand(concern))).to be_nil
    end

    it "declines when the target never asks for the replay" do
      expect(described_class.expand(concern(target_body: ""))).to be_nil
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

      expect(described_class.expand(source)).to be_nil
    end

    # Same ambiguity rule the outward direction has: one block, one target.
    it "declines a stored block replayed against more than one target" do
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

      expect(described_class.expand(source)).to be_nil
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
      expanded = described_class.expand(inherited)

      expect(inherited).not_to include("extend")
      expect(expanded).to include("class Wrap::Target\n      def installed")
      expect(expanded.scan("def installed").size).to eq(2)
      expect(Prism.parse(expanded).success?).to be(true)
    end

    # Ruby's ancestry is transitive, so this pass's has to be: `Target < Source`
    # reaches `keep` through `Source`, exactly as a direct subclass would.
    it "reaches a DSL inherited through an intermediate class" do
      expect(described_class.expand(inherited(target_super: "Source"))).to include("class Wrap::Target\n      def installed")
    end

    it "declines when the target never asks for the replay" do
      expect(described_class.expand(inherited.sub("    apply(Source)\n", ""))).to be_nil
    end

    it "adds nothing on a second pass over its own output" do
      expect(described_class.expand(described_class.expand(inherited))).to be_nil
    end

    # Reopening a class under a different superclass is not something to reason
    # about, but walking the chain must not hang on it either.
    it "terminates on a superclass chain that loops" do
      source = inherited(source_super: "Target", target_super: "Source")

      expect { described_class.expand(source) }.not_to raise_error
    end

    # An unresolvable superclass is simply not an edge — a class inheriting from
    # something declared elsewhere still resolves its own `extend`s.
    it "ignores a superclass it cannot resolve in this file" do
      source = inherited.sub("class Source < Base", "class Source < ::Elsewhere::Base")

      expect(described_class.expand(source)).to be_nil
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
      expanded = described_class.expand(splat)

      expect(expanded).to include("class Wrap::Target\n      def installed_first")
      expect(expanded).to include("class Wrap::Target\n      def installed_second")
      expect(Prism.parse(expanded).success?).to be(true)
    end

    it "resolves a single argument through the same iteration" do
      expanded = described_class.expand(splat(sources: %w[First], applied: "apply(First)"))

      expect(expanded).to include("class Wrap::Target\n      def installed_first")
      expect(expanded).not_to include("installed_second")
    end

    # The claim is about provenance, not about which yielded value is "the
    # element" — so it does not depend on knowing what the method does. Any
    # call on a handed receiver hands its block values that came from the
    # caller, including ones no first-parameter rule would survive:
    # `inject` yields the memo first, `each_with_index` an index second.
    it "does not depend on which method does the yielding" do
      %w[each map select each_with_index reverse_each each_entry tap].each do |iteration|
        expect(described_class.expand(splat(iteration: iteration)))
          .to include("class Wrap::Target\n      def installed_first"), "#{iteration} was not read"
      end
    end

    it "reads a name bound anywhere in the block's parameters" do
      source = splat.sub("{ |mod| mod.keep(self) }", "{ |index, mod| mod.keep(self) }")

      expect(described_class.expand(source)).to include("class Wrap::Target\n      def installed_first")
    end

    it "adds nothing on a second pass over its own output" do
      expect(described_class.expand(described_class.expand(splat))).to be_nil
    end

    it "declines a receiver that is neither a parameter nor bound from one" do
      source = splat.sub("modules.reverse_each { |mod| mod.keep(self) }",
                         "Registry.all.reverse_each { |mod| mod.keep(self) }")

      expect(described_class.expand(source)).to be_nil
    end

    # A destructuring target carries no name — the same reason a method's
    # would be skipped, not a rule of its own.
    it "declines a block that destructures what it is yielded" do
      source = splat.sub("{ |mod| mod.keep(self) }", "{ |(mod, _extra)| mod.keep(self) }")

      expect(described_class.expand(source)).to be_nil
    end

    it "follows a value through a nested iteration" do
      source = splat.sub("modules.reverse_each { |mod| mod.keep(self) }",
                         "modules.each { |group| group.each { |mod| mod.keep(self) } }")

      expect(described_class.expand(source)).to include("class Wrap::Target\n      def installed_first")
    end
  end
end
