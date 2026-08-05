require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::AST::MultiWriteDecomposer do
  def multi_write(source)
    RbsInfer::Analyzer.find_all_nodes(Prism.parse(source).value) { |n| n.is_a?(Prism::MultiWriteNode) }.first
  end

  describe ".ivar_name_pairs" do
    it "pairs each ivar target with the value that lands in it" do
      node = multi_write("@user, @filter, @expanded = user, filter, expanded")

      expect(described_class.ivar_name_pairs(node).map { |name, value| [name, value.name] })
        .to eq([["user", :user], ["filter", :filter], ["expanded", :expanded]])
    end

    it "pairs by position, not by name" do
      node = multi_write("@a, @b = b, a")

      expect(described_class.ivar_name_pairs(node).map { |name, value| [name, value.name] })
        .to eq([["a", :b], ["b", :a]])
    end

    it "skips non-ivar targets while keeping the others aligned" do
      node = multi_write("@a, local, @c = 1, 2, 3")

      expect(described_class.ivar_name_pairs(node).map { |name, value| [name, value.value] })
        .to eq([["a", 1], ["c", 3]])
    end

    it "declines to pair a single value destructured at runtime" do
      expect(described_class.ivar_name_pairs(multi_write("@a, @b = pair"))).to be_empty
    end

    it "declines to pair when a splat redistributes the values" do
      expect(described_class.ivar_name_pairs(multi_write("@a, *@rest = 1, 2, 3"))).to be_empty
      expect(described_class.ivar_name_pairs(multi_write("@a, @b = *values"))).to be_empty
    end

    it "declines to pair when the arities do not match" do
      expect(described_class.ivar_name_pairs(multi_write("@a, @b, @c = 1, 2"))).to be_empty
    end

    it "declines to pair a nested target" do
      expect(described_class.ivar_name_pairs(multi_write("@a, (@b, @c) = 1, [2, 3]")).map(&:first)).to eq(["a"])
    end

    it "returns nothing for a node that is not a multiple assignment" do
      expect(described_class.ivar_name_pairs(Prism.parse("@a = 1").value)).to be_empty
    end
  end

  describe ".ivar_target_names" do
    it "names every ivar written, including targets it would not pair" do
      expect(described_class.ivar_target_names(multi_write("@a, *@rest, @z = whatever")))
        .to eq(["a", "rest", "z"])
    end

    it "names the ivars of a value it cannot destructure statically" do
      expect(described_class.ivar_target_names(multi_write("@a, @b = pair"))).to eq(["a", "b"])
    end
  end
end
