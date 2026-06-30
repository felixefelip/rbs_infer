# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ReturnTypeResolver do
  subject(:resolver) do
    described_class.new(
      target_file: "x.rb",
      target_class: "X",
      method_type_resolver: nil,
      constant_resolver: nil
    )
  end

  # Parses a single `def` and returns its Prism::DefNode.
  def def_node(source)
    RbsInfer::Analyzer.find_all_nodes(Prism.parse(source).value) { |n| n.is_a?(Prism::DefNode) }.first
  end

  describe "#unconditional_nil_tail?" do
    it "is true for a straight-line call tail (e.g. a `find_each` iterator)" do
      defn = def_node(<<~RUBY)
        def run
          scope.find_each { |x| x.touch }
        end
      RUBY
      expect(resolver.send(:unconditional_nil_tail?, defn)).to be(true)
    end

    it "is true for a trailing nil literal / empty-ish body" do
      expect(resolver.send(:unconditional_nil_tail?, def_node("def run\n  puts 1\nend"))).to be(true)
    end

    it "is false for a trailing modifier-if (its value branch can be non-nil)" do
      defn = def_node(<<~RUBY)
        def run
          rel = lookup
          rel.destroy_all if rel
        end
      RUBY
      expect(resolver.send(:unconditional_nil_tail?, defn)).to be(false)
    end

    it "is false for a trailing case/when without a value-bearing else" do
      defn = def_node(<<~RUBY)
        def run
          case kind
          when :a then do_a
          end
        end
      RUBY
      expect(resolver.send(:unconditional_nil_tail?, defn)).to be(false)
    end

    it "is false for a nil def body" do
      expect(resolver.send(:unconditional_nil_tail?, def_node("def run\nend"))).to be(false)
    end
  end
end
