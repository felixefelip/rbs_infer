# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::ClassEvalExpander do
  def expand(source)
    described_class.expand(source)
  end

  it "rewrites a class_eval block into a reopen of the receiver" do
    expect(expand("Foo.class_eval do\n  def bar\n    1\n  end\nend\n"))
      .to eq("class Foo\n  def bar\n    1\n  end\nend\n")
  end

  # The `.expanded/` sidecar is read while debugging, so the rewrite keeps the source's
  # own layout: the body is sliced from the start of its LINE (not from its first
  # token, which dropped the first line's indentation and nothing else) and the closing
  # `end` is aligned to the call it replaces. An in-place rewrite puts `class Foo` where
  # `Foo.class_eval do` stood, so the body is already one level in and the re-indent
  # BlockReopen does has nothing to move — the heredoc here says so directly, and is the
  # in-place half of the guarantee `block_reopen_spec.rb` pins for the relocating one.
  it "keeps the source layout, including a nested call and a heredoc" do
    expect(expand("class Wrap\n  Foo.class_eval do\n    def bar\n      1\n    end\n  end\nend\n"))
      .to eq("class Wrap\n  class Foo\n    def bar\n      1\n    end\n  end\nend\n")

    heredoc = "Foo.class_eval do\n  def bar\n    <<~SQL\n      select 1\n    SQL\n  end\nend\n"
    expect(expand(heredoc)).to eq(heredoc.sub("Foo.class_eval do", "class Foo"))
  end

  # A body opening on the same line as `do` has no indentation to reclaim, and must not
  # pull in the space after `do` — it is indented like any other, from a margin of zero.
  it "does not pull in the space after `do` for a single-line body" do
    expect(expand("Foo.class_eval do def bar; 1; end end\n"))
      .to eq("class Foo\n  def bar; 1; end\nend\n")
  end

  it "rewrites module_eval the same way" do
    expect(expand("Foo.module_eval do\n  def bar; 1; end\nend\n"))
      .to eq("class Foo\n  def bar; 1; end\nend\n")
  end

  it "rewrites a namespaced receiver, keeping its full path" do
    expect(expand("Foo::Bar.class_eval do\n  def baz; 1; end\nend\n"))
      .to eq("class Foo::Bar\n  def baz; 1; end\nend\n")
  end

  it "keeps a cbase receiver absolute" do
    expect(expand("::Foo.class_eval do\n  def bar; 1; end\nend\n"))
      .to eq("class ::Foo\n  def bar; 1; end\nend\n")
  end

  it "leaves the surrounding source alone" do
    expanded = expand(<<~RUBY)
      class Other
        def keep; 1; end
      end

      Foo.class_eval do
        def bar; 2; end
      end

      TAIL = 3
    RUBY

    expect(expanded).to include("class Other\n  def keep; 1; end\nend")
    expect(expanded).to include("class Foo\n  def bar; 2; end\nend")
    expect(expanded).to include("TAIL = 3")
  end

  it "rewrites an empty block into an empty reopen" do
    expect(expand("Foo.class_eval do\nend\n")).to eq("class Foo\n\nend\n")
  end

  # A nested block is rewritten on a later pass, once the outer one is an ordinary
  # class body. Replacing both at once would corrupt the source, since the inner
  # match's offsets sit inside the outer's replaced range.
  it "rewrites nested class_eval blocks, outermost first" do
    expanded = expand(<<~RUBY)
      Outer.class_eval do
        Inner.class_eval do
          def deep; 1; end
        end
      end
    RUBY

    expect(expanded).to include("class Outer")
    expect(expanded).to include("class Inner")
    expect(expanded).not_to include("class_eval")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  # Only nesting costs a pass, and the pass bound comes from the source — so
  # depth has no ceiling to hit. A fixed ten stopped at eleven nested reopenings
  # and returned a file still holding a `class_eval`: wrong, and an output this
  # expander wanted to rewrite again.
  it "converges however deep the nesting goes" do
    source = "def leaf\n  1\nend\n"
    12.downto(1) { |i| source = "C#{i}.class_eval do\n#{source}end\n" }
    expanded = expand(source)

    expect(expanded).not_to include("class_eval")
    expect(expanded).to include("class C12")
    expect(expand(expanded)).to be_nil
  end

  # The other half of the same claim: what costs a pass is nesting, not count.
  it "rewrites any number of non-overlapping calls in one pass" do
    source = (1..15).map { |i| "C#{i}.class_eval do\n  def m#{i}; 1; end\nend\n" }.join

    expect(described_class.expand_once(source)).not_to include("class_eval")
  end

  describe "declines" do
    # `instance_eval`'s default definee is the receiver's SINGLETON class, so
    # rewriting it to `class X` would attribute the def to the instance side — the
    # wrong half. steep#135 declines it for the same reason.
    it "leaves instance_eval alone" do
      expect(expand("Foo.instance_eval do\n  def bar; 1; end\nend\n")).to be_nil
    end

    # The body is not source this can read — the README's `eval` exclusion.
    it "leaves the string form alone" do
      expect(expand(%(Foo.class_eval "def bar; 1; end"\n))).to be_nil
    end

    # Reopens whatever class the value happens to be, which the shape does not say.
    it "leaves a non-constant receiver alone" do
      expect(expand("obj.class_eval do\n  def bar; 1; end\nend\n")).to be_nil
      expect(expand("self.class_eval do\n  def bar; 1; end\nend\n")).to be_nil
    end

    it "returns nil when the source mentions neither name" do
      expect(expand("class Foo\n  def bar; 1; end\nend\n")).to be_nil
    end

    it "returns nil on a parse error rather than rewriting half a file" do
      expect(expand("Foo.class_eval do\n  def bar\n")).to be_nil
    end
  end

  it "is idempotent over its own output" do
    once = expand("Foo.class_eval do\n  def bar; 1; end\nend\n")

    expect(expand(once)).to be_nil
  end

  it "is registered on the SourceExpanders seam" do
    expect(RbsInfer::Project::SourceExpanders.expanders).to include(described_class)
  end
end
