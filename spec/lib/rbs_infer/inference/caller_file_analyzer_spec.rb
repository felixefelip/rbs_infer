require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::CallerFileAnalyzer do
  let(:analyzer) do
    described_class.new(
      target_class: "Foo",
      method_type_resolver: nil
    )
  end

  describe "#unwrap_outer_nilable (private)" do
    # Regression for the per-action narrowing path in helper inference:
    # `ivar_write_types` (rbs_infer#4) emits a trailing `?` for ivars
    # not written in `initialize`. The element-type lookup must strip
    # that `?` before resolving `each` via RBS — otherwise an iterator
    # over `@posts: Post::ActiveRecord_Relation?` yields no element
    # type and downstream block-param resolution falls back to the
    # ivar's wide type.

    it "leaves a non-nilable type unchanged" do
      expect(analyzer.send(:unwrap_outer_nilable, "Post::ActiveRecord_Relation"))
        .to eq("Post::ActiveRecord_Relation")
    end

    it "strips a single trailing ? from a bare type" do
      expect(analyzer.send(:unwrap_outer_nilable, "Post::ActiveRecord_Relation?"))
        .to eq("Post::ActiveRecord_Relation")
    end

    it "strips ? and outer parens from a parenthesized type" do
      expect(analyzer.send(:unwrap_outer_nilable, "(Post | (Post & Post::Validated))?"))
        .to eq("Post | (Post & Post::Validated)")
    end

    it "leaves parens that are not the outer wrap alone" do
      # `(A) | (B)` has parens at start/end but they don't pair
      # together as a single outer wrap, so don't strip them.
      expect(analyzer.send(:unwrap_outer_nilable, "(A) | (B)?"))
        .to eq("(A) | (B)")
    end

    it "is a no-op for nil or empty input" do
      expect(analyzer.send(:unwrap_outer_nilable, nil)).to be_nil
      expect(analyzer.send(:unwrap_outer_nilable, "")).to eq("")
    end
  end

  describe "#balanced_outer_parens? (private)" do
    it "is true for `(A | B)`" do
      expect(analyzer.send(:balanced_outer_parens?, "(A | B)")).to be(true)
    end

    it "is true for `((A & B) | C)` (nested but single outer wrap)" do
      expect(analyzer.send(:balanced_outer_parens?, "((A & B) | C)")).to be(true)
    end

    it "is false for `(A) | (B)` (two separate paren groups)" do
      expect(analyzer.send(:balanced_outer_parens?, "(A) | (B)")).to be(false)
    end

    it "is false for `A | B` (no parens at all)" do
      expect(analyzer.send(:balanced_outer_parens?, "A | B")).to be(false)
    end
  end
end
