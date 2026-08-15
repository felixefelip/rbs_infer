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
end
