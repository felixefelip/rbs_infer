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

  # Including a bare call whose `self` is the module itself: there `self` IS the
  # union, so the union is the answer.
  it "declines when a bare call sits outside every declared branch" do
    write_two_extenders
    write("app/elsewhere.rb", <<~RUBY)
      class Elsewhere
        def run
          stamp(3)
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
