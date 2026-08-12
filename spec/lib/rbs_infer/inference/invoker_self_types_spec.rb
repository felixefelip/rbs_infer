# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# The declared self type of a module is every host it has; the self type at a
# CALL SITE is the host that made the call. Handing a parameter the first where
# the second is readable states a fact the code does not
# (felixefelip/rbs_infer#222).
RSpec.describe RbsInfer::Inference::InvokerSelfTypes do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def narrower(files = Dir["app/**/*.rb"])
    described_class.new(
      source_index: RbsInfer::Project::SourceIndex.new(files),
      parse_cache: RbsInfer::Project::ParseCache.new
    )
  end

  # `Bar` and `Baz` both extend the module; only `Bar` calls `stamp`.
  def write_two_extenders(baz_body: "")
    write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Foo
          def stamp(value)
            value
          end
        end

        module Baz
          extend Wrap::Foo
      #{baz_body}
        end

        class Bar
          extend Wrap::Foo

          stamp(1)
        end
      end
    RUBY
  end

  let(:declared) { "((singleton(Wrap::Bar)) | (singleton(Wrap::Baz)))" }

  it "keeps only the branch that calls the method" do
    write_two_extenders

    expect(narrower.narrow(method_name: "stamp", declared: declared))
      .to eq("singleton(Wrap::Bar)")
  end

  it "leaves the declaration alone when every branch calls it" do
    write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Foo
          def stamp(value)
            value
          end
        end

        module Baz
          extend Wrap::Foo

          stamp(2)
        end

        class Bar
          extend Wrap::Foo

          stamp(1)
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end

  # What `self` is inside the callee is then the receiver's type, which this
  # walk does not resolve — so the picture is no longer whole and nothing is
  # subtracted.
  it "declines when the method is called on a receiver anywhere" do
    write_two_extenders
    write("app/elsewhere.rb", <<~RUBY)
      class Elsewhere
        def run(target)
          target.stamp(3)
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end

  # The observations are gathered by method NAME across the corpus, so most of
  # them belong to other methods. A class resolves a bare call in its own
  # ancestry, and the declaration already lists every class whose ancestry
  # carries this module — so one that is not listed is calling something else.
  # Two namespaces with the same method names used to blank each other's
  # narrowing (felixefelip/rbs_infer#227).
  it "ignores a bare call from a class the declaration does not list" do
    write_two_extenders
    write("app/elsewhere.rb", <<~RUBY)
      class Elsewhere
        def run
          stamp(3)
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared))
      .to eq("singleton(Wrap::Bar)")
  end

  # A MODULE's instance method is the one caller that cannot be dismissed that
  # way: `self` there is whoever mixes THAT module in, a name this record does
  # not carry, and it might be one of ours — a sibling concern sharing a host.
  it "declines when a bare call sits in a module's instance method" do
    write_two_extenders
    write("app/sibling.rb", <<~RUBY)
      module Sibling
        def run
          stamp(3)
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end

  # Including the module's own body, where `self` is the whole union.
  it "declines when the module itself calls the method" do
    write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Foo
          def stamp(value)
            value
          end

          def relay(value)
            stamp(value)
          end
        end

        module Baz
          extend Wrap::Foo
        end

        class Bar
          extend Wrap::Foo

          stamp(1)
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end

  # An uncalled method says nothing about its `self`. Narrowing to the empty set
  # would be inventing a fact rather than reading one.
  it "declines when nothing calls the method" do
    write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Foo
          def stamp(value)
            value
          end
        end
      end
    RUBY

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end

  # A single host has nothing to subtract, and the walk is skipped entirely.
  it "leaves a one-branch declaration alone" do
    write_two_extenders

    expect(narrower.narrow(method_name: "stamp", declared: "(Card & Card::Entropic)"))
      .to eq("(Card & Card::Entropic)")
  end

  # A call written at the start of a line is what `files_with_bare_call` matches;
  # this one is not, and missing it would have narrowed `Baz` away wrongly.
  it "sees a bare call that is not at the start of a line" do
    write_two_extenders(baz_body: "    x = stamp(2)")

    expect(narrower.narrow(method_name: "stamp", declared: declared)).to eq(declared)
  end
end
