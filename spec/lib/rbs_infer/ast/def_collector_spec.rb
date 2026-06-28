require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::DefCollector do
  def collect(source, target_class: nil)
    result = Prism.parse(source)
    visitor = described_class.new(target_class: target_class)
    result.value.accept(visitor)
    visitor
  end

  def def_named(collector, name)
    collector.defs.find { |d| d.name == name.to_sym }
  end

  it "atribui defs de `class_methods do` (Concern) ao owner ClassMethods" do
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

    collector = collect(source, target_class: "Greetable")

    banner = def_named(collector, :banner)
    expect(collector.owner_of(banner)).to eq("ClassMethods")
    # Defined as a module instance method (mixed in via `extend ...::ClassMethods`),
    # not a `def self.` singleton — so not flagged as a class method here.
    expect(collector.class_method?(banner)).to be(false)

    greet = def_named(collector, :greet)
    expect(collector.owner_of(greet)).to be_nil
  end

  it "restaura o owner ao sair do bloco class_methods" do
    source = <<~RUBY
      module Greetable
        class_methods do
          def inside
          end
        end

        def outside
        end
      end
    RUBY

    collector = collect(source, target_class: "Greetable")

    expect(collector.owner_of(def_named(collector, :inside))).to eq("ClassMethods")
    expect(collector.owner_of(def_named(collector, :outside))).to be_nil
  end
end
