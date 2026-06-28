# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/class_methods_expander"

RSpec.describe RbsInfer::Extensions::Rails::ClassMethodsExpander do
  def expand(source)
    described_class.expand(source)
  end

  it "returns nil for sources without class_methods" do
    expect(expand(<<~RUBY)).to be_nil
      module Greetable
        def greet; "hi"; end
      end
    RUBY
  end

  it "returns nil when class_methods is called with arguments (not the Concern DSL)" do
    expect(expand(<<~RUBY)).to be_nil
      class Registry
        def class_methods(klass)
          yield klass
        end
      end
    RUBY
  end

  it "rewrites `class_methods do ... end` into a nested ClassMethods module" do
    expanded = expand(<<~RUBY)
      module Greetable
        extend ActiveSupport::Concern

        class_methods do
          def banner
            "hi"
          end
        end

        def greet
          "hello"
        end
      end
    RUBY

    expect(expanded).to include("module ClassMethods")
    expect(expanded).to include("def banner")
    expect(expanded).not_to include("class_methods do")
  end

  it "attributes the rewritten defs to a ClassMethods owner through the full collector" do
    source = <<~RUBY
      module Greetable
        extend ActiveSupport::Concern

        class_methods do
          def banner
            "hi"
          end
        end

        def greet
          "hello"
        end
      end
    RUBY

    expanded = expand(source)
    result = Prism.parse(expanded)
    collector = RbsInfer::Inference::ClassMemberCollector.new(
      comments: result.comments,
      lines: expanded.lines,
      target_class: "Greetable"
    )
    result.value.accept(collector)

    banner = collector.members.find { |m| m.name == "banner" }
    expect(banner.kind).to eq(:method)
    expect(banner.owner).to eq("ClassMethods")

    greet = collector.members.find { |m| m.name == "greet" }
    expect(greet.owner).to be_nil
  end
end
