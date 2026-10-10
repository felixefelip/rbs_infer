# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ReturnTypeResolver do
  subject(:resolver) do
    described_class.new(
      target_file: "x.rb",
      target_class: "X",
      method_type_resolver: nil
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

    # felixefelip/rbs_infer#287. `self` is the RECEIVER, and a setter returns
    # neither the receiver nor anything its identity implies: `def user=(v);
    # @user = v; end` on a `Widget` hands `super`'s caller the ASSIGNED widget.
    # Emitting `-> self` there says the assignment came back, which it did not.
    it "is false for a setter, even when its body evaluates to the target class" do
      setter = RbsInfer::Inference::Member.new(
        kind: :method, name: "user=", signature: "user=: (X value) -> untyped", visibility: :public
      )

      expect(resolver.send(:self_return?, setter, "X", self_types)).to be(false)
      # ...while the same body in a non-setter still resolves to `self`.
      expect(resolver.send(:self_return?, member(:method), "X", self_types)).to be(true)
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

    it "is true for a def with no body" do
      expect(resolver.send(:unconditional_nil_tail?, def_node("def run\nend"))).to be(true)
      expect(resolver.send(:unconditional_nil_tail?, def_node("def run; end"))).to be(true)
    end

    it "is false without a def to read" do
      expect(resolver.send(:unconditional_nil_tail?, nil)).to be(false)
    end
  end

  # felixefelip/rbs_infer#286. The predicate decides whether a body's `return`
  # widens the method's type to `T?`. It used to answer from the parse alone, so
  # a guard the checker had already refuted still nilablized the signature. It
  # now takes the ranges Steep proved dead and skips the `return`s inside them.
  describe "#has_nil_return?" do
    # One dead `return` and one live one, so the filter has to answer per node
    # rather than for the method as a whole.
    let(:source) do
      <<~RUBY
        def label
          return if refuted?

          return nil if genuinely_unknown?

          "x"
        end
      RUBY
    end

    let(:defn) { def_node(source) }
    let(:dead_guard) { range_of("return if") }
    let(:live_guard) { range_of("return nil") }

    # The byte range of the `return` keyword opening the given line.
    def range_of(snippet)
      start = source.index(snippet)
      start...(start + "return".bytesize)
    end

    it "counts a bare `return` when nothing is proved dead" do
      expect(resolver.send(:has_nil_return?, defn, dead_ranges: [])).to be(true)
    end

    it "counts a `return` a range does not cover" do
      # A dead branch elsewhere in the file says nothing about these two.
      elsewhere = (source.bytesize + 10)...(source.bytesize + 20)
      expect(resolver.send(:has_nil_return?, defn, dead_ranges: [elsewhere])).to be(true)
    end

    it "still counts the live `return` when only the other one is dead" do
      expect(resolver.send(:has_nil_return?, defn, dead_ranges: [dead_guard])).to be(true)
    end

    it "counts nothing once every `return` is proved dead" do
      expect(resolver.send(:has_nil_return?, defn, dead_ranges: [dead_guard, live_guard])).to be(false)
    end

    it "ignores a `return` with a value, dead or not" do
      valued = def_node("def label\n  return \"x\" if cond?\n\n  \"y\"\nend\n")
      expect(resolver.send(:has_nil_return?, valued, dead_ranges: [])).to be(false)
    end
  end
end
