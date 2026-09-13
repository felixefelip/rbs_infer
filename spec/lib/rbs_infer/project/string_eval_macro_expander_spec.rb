# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/string_eval_macro_expander"

RSpec.describe RbsInfer::Project::StringEvalMacroExpander do
  # The sidecar as `steep check` writes it: what each call site evals, keyed by
  # `path:line:column`. Reading a macro is Steep's half (felixefelip/steep#169)
  # and is tested there; this side decides only where the source goes.
  def sidecar_for(call_sites)
    RbsInfer::Project::StringEvalSidecar.new(call_sites, base_dir: Dir.pwd)
  end

  def reopens(source, call_sites, path: "app/models/article.rb")
    described_class.reopens(source, path: path, sidecar: sidecar_for(call_sites))
  end

  # A method, not a constant: a constant written inside `RSpec.describe` lands
  # on Object and collides with the same name in another spec file.
  def accessor
    <<~RUBY
      def content
        @content
      end

      def content=(value)
        @content = value
      end
    RUBY
  end

  it "appends the source the call site writes, to the class that made the call" do
    source = <<~RUBY
      class Article
        has_slot :content
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:2:2" => [accessor] })).to eq(<<~RUBY)
      class Article
        def content
          @content
        end

        def content=(value)
          @content = value
        end
      end
    RUBY
  end

  it "renders one reopen per class, with every chunk the call writes" do
    source = <<~RUBY
      class Article
        has_slot :content
      end

      class Photo
        has_slot :caption
      end
    RUBY

    result = reopens(source, {
                       "app/models/article.rb:2:2" => ["def content; end"],
                       "app/models/article.rb:6:2" => ["def caption; end", "def caption=(v); end"]
                     })

    expect(result).to eq(<<~RUBY)
      class Article
        def content; end
      end

      class Photo
        def caption; end
        def caption=(v); end
      end
    RUBY
  end

  it "reopens the qualified name of a nested class" do
    source = <<~RUBY
      module Blog
        class Entry
          has_slot :content
        end
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:3:4" => ["def content; end"] }))
      .to include("class Blog::Entry")
  end

  it "reopens a module as a module" do
    source = <<~RUBY
      module Sluggable
        has_slot :slug
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:2:2" => ["def slug; end"] }))
      .to start_with("module Sluggable")
  end

  # A macro call written inside a `def` runs when that method runs, on whatever
  # `self` is then — which this cannot name.
  it "ignores a call written inside a method" do
    source = <<~RUBY
      class Article
        def install
          has_slot :content
        end
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:3:4" => ["def content; end"] })).to be_nil
  end

  it "returns nil when no call site in the file is recorded" do
    source = <<~RUBY
      class Article
        has_slot :content
      end
    RUBY

    expect(reopens(source, { "app/models/photo.rb:2:2" => ["def content; end"] })).to be_nil
  end

  it "returns nil when the sidecar is empty" do
    expect(reopens("class Article\n  has_slot :content\nend\n", {})).to be_nil
  end

  # A chunk whose value the call site does not fix comes through as a hole, and
  # a class given a reader whose writer was dropped is worse than one given
  # neither.
  it "declines a call site the checker read only in part" do
    source = <<~RUBY
      class Article
        has_slot :content
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:2:2" => ["def content; end", nil] })).to be_nil
  end

  # The heredoc a macro is written with carries the gem's indentation; the
  # reopen supplies its own.
  it "dedents what it is handed and indents it into the reopen" do
    source = <<~RUBY
      class Article
        has_slot :content
      end
    RUBY

    written = "      def content\n        @content\n      end\n"

    expect(reopens(source, { "app/models/article.rb:2:2" => [written] })).to eq(<<~RUBY)
      class Article
        def content
          @content
        end
      end
    RUBY
  end

  it "matches a call site recorded relative to the project when handed an absolute path" do
    source = <<~RUBY
      class Article
        has_slot :content
      end
    RUBY
    absolute = File.join(Dir.pwd, "app/models/article.rb")

    expect(reopens(source, { "app/models/article.rb:2:2" => ["def content; end"] }, path: absolute))
      .to include("def content; end")
  end

  # `class ::Article` declares the top-level Article and says so; folding it
  # into the lexical namespace would reopen a class the program does not have.
  it "keeps an absolute constant path out of the lexical namespace" do
    source = <<~RUBY
      module Outer
        class ::Article
          has_slot :content
        end
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:3:4" => ["def content; end"] }))
      .to start_with("class Article\n")
  end

  # A macro call under a condition runs on the same `self` as one written bare,
  # and the checker has already said what it defines there.
  it "reads a call written inside the class body's control flow" do
    source = <<~RUBY
      class Article
        if Rails.env.production?
          has_slot :content
        end
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:3:4" => ["def content; end"] })).to eq(<<~RUBY)
      class Article
        def content; end
      end
    RUBY
  end

  # A block's body runs on whoever calls it, which this cannot name.
  it "ignores a call written inside a block" do
    source = <<~RUBY
      class Article
        with_options shallow: true do
          has_slot :content
        end
      end
    RUBY

    expect(reopens(source, { "app/models/article.rb:3:4" => ["def content; end"] })).to be_nil
  end

  it "returns nil for a file it cannot parse" do
    expect(reopens("class Article", { "app/models/article.rb:1:0" => ["def content; end"] })).to be_nil
  end
end
