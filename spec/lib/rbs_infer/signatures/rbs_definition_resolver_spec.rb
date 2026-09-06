require "spec_helper"

RSpec.describe RbsInfer::Signatures::RbsDefinitionResolver do
  subject(:resolver) { described_class.new }

  describe "#type_param_string" do
    it "renders the exact params of a generic core class" do
      expect(resolver.type_param_string("Array")).to eq("[unchecked out E]")
      expect(resolver.type_param_string("Hash")).to eq("[unchecked out K, unchecked out V]")
    end

    it "returns '' for a non-generic class" do
      expect(resolver.type_param_string("String")).to eq("")
    end

    it "returns '' for an unknown class" do
      expect(resolver.type_param_string("Totally::Unknown::Klass")).to eq("")
    end

    it "returns '' for an unparseable name instead of raising" do
      expect(resolver.type_param_string("@@ not a type")).to eq("")
    end
  end

  describe "#parse_intersection_components" do
    it "splits `A & B` into components" do
      expect(resolver.parse_intersection_components("Order & Order::Validated"))
        .to eq(["Order", "Order::Validated"])
    end

    it "splits `(A & B)` (parenthesized) into components" do
      expect(resolver.parse_intersection_components("(Order & Order::Validated)"))
        .to eq(["Order", "Order::Validated"])
    end

    it "returns nil for a single nominal type" do
      expect(resolver.parse_intersection_components("Order")).to be_nil
    end

    it "returns nil for unparseable strings" do
      expect(resolver.parse_intersection_components("@@ not a type")).to be_nil
    end

    it "splits three-component intersections" do
      expect(resolver.parse_intersection_components("A & B & C"))
        .to eq(["A", "B", "C"])
    end
  end

  describe "#resolve_via_rbs_builder with an intersection receiver" do
    # The resolver consults the project's RBS env. When `class_name` is an
    # intersection (e.g. `Order & Order::Validated` produced by
    # `Relation::Methods#each` yielding `(Model & ValidatedModel)`), it must
    # split and try each component right-to-left. Without that, the lookup
    # silently fails and `partial_locals_collector#infer_local_value_type`
    # drops the local — which was the regression on
    # `_products.rbs` (no `attr_reader products:` emitted).
    it "falls back through the intersection to find the method" do
      # Use `Integer & Comparable` — both are present in core RBS.
      # `Integer#succ` exists on the left component; the resolver should
      # return a result instead of nil.
      result = resolver.resolve_via_rbs_builder(:instance, "Integer & Comparable", :succ, arg_types: nil)
      expect(result).not_to be_nil
    end
  end

  # RBS declares `Kernel#class` as `() -> Class`, which loses the one thing the
  # call states: WHICH class. Read literally, `self.class` typed a receiver
  # `Class`, which names no target, and every `self.class.foo(x)` call site was
  # dropped (felixefelip/rbs_infer#296).
  describe "#resolve_via_rbs_builder for Kernel#class" do
    it "answers the receiver's own singleton, not the declared `Class`" do
      expect(resolver.resolve_via_rbs_builder(:instance, "String", :class, arg_types: nil))
        .to eq("singleton(String)")
    end

    it "leaves the singleton side alone: `String.class` is `Class` as declared" do
      expect(resolver.resolve_via_rbs_builder(:singleton, "String", :class, arg_types: nil))
        .to eq("Class")
    end
  end
end
