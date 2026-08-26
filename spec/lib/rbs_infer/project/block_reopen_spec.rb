# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# The relocating half of the rewrite. `ClassEvalExpander` leaves a block where it stands,
# so its body is already at the column it belongs at; the two expanders that MOVE one emit
# it under a reopening at column 0, and it arrives carrying the margin of wherever it was
# written — two or three scopes in, for the shapes that need relocating at all.
#
# Bringing it back is a rewrite of the source's own bytes, and that is the whole risk here:
# some of those bytes are string DATA, where a column is not layout but content.
# felixefelip/rbs_infer#239 re-indented the lot and changed what a heredoc said, which
# nothing caught — a heredoc's contents reach no inferred type, and nothing in the dummy
# has one inside a moved block, so the `.expanded/` snapshots had none to show. Hence this
# file, and hence the assertions RUN both versions: comparing strings would only say the
# bytes are what I expected, where `eval` says the program still means what it meant.
#
# Bodies below are written at the column they really sit at, with `<<-` rather than `<<~`
# so nothing strips it. The margin is the input.
RSpec.describe RbsInfer::Project::BlockReopen do
  # `base.class_eval do … end` nested two scopes deep — the `included`-hook shape, and the
  # margin the relocation has to remove.
  def hook(body)
    "class A\n  module B\n    def self.included(base)\n      base.class_eval do\n#{body}      end\n    end\n  end\nend\n"
  end

  def relocated(body, singleton: false)
    source = hook(body)
    call = nil
    Prism.parse(source).value.breadth_first_search do |node|
      call = node if node.is_a?(Prism::CallNode) && node.name == :class_eval
      false
    end

    described_class.appended(source: source, block: call.block, kind: "class", target: "Host", singleton: singleton)
  end

  # What `check` returns from the program as WRITTEN, and from the program as expanded.
  # Equal is the whole point: relocation is a move, not an edit, and only running both can
  # say whether a given byte was layout or content.
  def both_ways(body)
    eval("#{hook(body)}\nclass Written; include A::B; end")
    eval(relocated(body))

    [Written.new.check, Host.new.check]
  ensure
    %i[A Written Host].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
  end

  it "brings a moved body back to one level in" do
    body = <<-RUBY
        def check
          "hook"
        end
    RUBY

    expect(relocated(body)).to eq("class Host\n  def check\n    \"hook\"\n  end\nend\n")
  end

  # `base.singleton_class.class_eval` runs the same block against the class object, so the
  # `def`s land in the singleton — one more scope to open, and one more level to indent to.
  # The body itself is moved by exactly the same rule.
  it "nests a singleton replay's body inside a `class << self`" do
    body = <<-RUBY
        def check
          "hook"
        end
    RUBY

    expect(relocated(body, singleton: true))
      .to eq("class Host\n  class << self\n    def check\n      \"hook\"\n    end\n  end\nend\n")
  end

  it "keeps the body's own shape while moving it" do
    body = <<-RUBY
        def check
          if 1 > 0
            "yes"
          end
        end
    RUBY

    expect(relocated(body)).to eq("class Host\n  def check\n    if 1 > 0\n      \"yes\"\n    end\n  end\nend\n")
  end

  # `<<~` measures its margin against its own content lines, so leaving them alone is what
  # makes the result identical. Moving them all by the same amount would work here too —
  # it is the two below that make "leave the data alone" the rule rather than "shift it
  # uniformly", and this one is here so the common case is covered by the rule that has to
  # hold for them.
  it "does not touch a squiggly heredoc" do
    written, expanded = both_ways(<<-RUBY)
        def check
          <<~SQL
            SELECT 1
              FROM t
          SQL
        end
    RUBY

    expect(expanded).to eq(written)
    expect(expanded).to eq("SELECT 1\n  FROM t\n")
  end

  # Here the margin IS the content, and a `<<-` terminator's column is free — so the
  # terminator moving while its content does not would be legal, and still wrong.
  it "does not touch a dash heredoc's deliberate margin" do
    written, expanded = both_ways(<<-RUBY)
        def check
          <<-RAW
      indented on purpose
          RAW
        end
    RUBY

    expect(expanded).to eq(written)
    expect(expanded).to eq("      indented on purpose\n")
  end

  # A plain heredoc's terminator must be at column 0, so moving that line is a SyntaxError
  # rather than merely a different string.
  it "leaves a plain heredoc's terminator at column 0" do
    written, expanded = both_ways(<<-RUBY)
        def check
          <<RAW
      literal
RAW
        end
    RUBY

    expect(expanded).to eq(written)
    expect(expanded).to eq("      literal\n")
  end

  it "does not touch a multi-line string" do
    written, expanded = both_ways(<<-RUBY)
        def check
          "one
        two"
        end
    RUBY

    expect(expanded).to eq(written)
    expect(expanded).to eq("one\n        two")
  end

  # A literal is ONE span, interpolations and all. Moving an interpolation's lines happens
  # to be safe — Ruby measures a `<<~` margin against the content lines only, so this
  # string survives either way — which is why the bytes are asserted too: what is pinned
  # is the rule as implemented, that descent stops at the literal rather than at its parts.
  it "does not touch an interpolation inside a heredoc" do
    body = <<-'RUBY'
        def check
          <<~TXT
            a#{
              1 + 1
            }b
              indented
          TXT
        end
    RUBY

    written, expanded = both_ways(body)
    expect(expanded).to eq(written)
    expect(expanded).to eq("a2b\n  indented\n")
    expect(relocated(body)).to include("\n            a\#{\n              1 + 1\n            }b\n")
  end

  # The one hazard Prism reports as a comment rather than a node — and `=begin` is only a
  # comment at column 0, so there is nowhere to move it to. The whole body stays put, which
  # is the old behaviour and still valid Ruby.
  it "declines to move a body containing an embdoc comment" do
    body = <<-RUBY
        def other
          1
        end
=begin
not code
=end
        def check
          "embdoc"
        end
    RUBY

    expect(relocated(body)).to include("\n=begin\nnot code\n=end\n")
    expect(relocated(body)).to include("\n        def check\n")
    expect(both_ways(body).uniq).to eq(["embdoc"])
  end
end
