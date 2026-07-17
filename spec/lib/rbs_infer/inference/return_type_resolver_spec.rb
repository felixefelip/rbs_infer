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

  describe "#self_return?" do
    let(:self_types) { Set.new(["X"]) }

    def member(kind)
      RbsInfer::Inference::Member.new(kind: kind, name: "build", signature: "build: () -> untyped", visibility: :public)
    end

    it "is true for an instance method returning its own class" do
      expect(resolver.send(:self_return?, member(:method), "X", self_types)).to be(true)
    end

    # RBS `self` is the type of the receiver, so in a singleton method it means
    # `singleton(X)` — not an instance. Emitting `self` for
    # `def self.instance; @instance ||= X.new; end` declares a type the body
    # does not have, and Steep rejects it outright ("Cannot allow method body
    # have type `::X` because declared as type `self`").
    it "is false for a class method returning an instance of its own class" do
      expect(resolver.send(:self_return?, member(:class_method), "X", self_types)).to be(false)
    end

    it "is false for any method returning some other class" do
      expect(resolver.send(:self_return?, member(:method), "Other", self_types)).to be(false)
    end
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
