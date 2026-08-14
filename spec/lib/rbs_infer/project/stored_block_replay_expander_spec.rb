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

    expect(expanded).to include("class Wrap::Target\n  def installed")
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

    expect(expanded).to include("module Wrap::Target\n  def installed")
    expect(Prism.parse(expanded).success?).to be(true)
  end
end
