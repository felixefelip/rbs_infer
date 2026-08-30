# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A delegated method accepts what the method it forwards to accepts. That rule was
# written as `() -> <return type>`: the return was resolved and the parameters were
# dropped, so `delegate :default_value?, to: :class` — a method taking `(key, value)`
# — came out as `def default_value?: () -> bool`, contradicted by its own call sites
# (felixefelip/rbs_infer#294).
#
# The parameters live in the declaration, so the RBS is what answers — the previous
# pass's output, the same way every cross-file type here converges.
RSpec.describe "a delegated method's signature" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def generate(target)
    RbsInfer::Analyzer.new(
      target_class: "Target", target_file: target, source_files: Dir["app/*.rb"]
    ).generate_rbs
  end

  it "copies the parameter list of the method it forwards to" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        delegate :stamp, to: :printer

        def printer
          Printer.new
        end
      end
    RUBY
    write("app/printer.rb", "class Printer\n  def stamp(label, times)\n    label\n  end\nend\n")
    write("sig/generated/printer.rbs", "class Printer\n  def stamp: (String label, ?Integer times) -> String\nend\n")

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String")
  end

  # `to: :class` forwards to `self.class`, so the receiver is the target's SINGLETON.
  # It used to be read by capitalizing the reader's name, which for `class` is the
  # constant `Class` — every lookup went to `::Class`, which has none of these methods.
  it "reads `to: :class` as the target's own singleton" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        delegate :stamp, to: :class

        def self.stamp(label, times)
          label
        end
      end
    RUBY
    write("sig/generated/target.rbs", "class Target\n  def self.stamp: (String label, Integer times) -> String\nend\n")

    expect(generate(target)).to include("def stamp: (String label, Integer times) -> String")
  end

  # And the singleton it reaches is the one the ancestry gives it: a concern's
  # `class_methods do` block lands on the HOST's singleton, which is what the
  # concern's `@type instance:` annotation names. This is the shape the report came
  # from — `delegate :default_value?, to: :class` inside an `ActiveSupport::Concern`.
  it "reads `to: :class` in a concern as the host's singleton" do
    target = write("app/mixin.rb", <<~RUBY)
      # @type instance: Host & Mixin
      module Mixin
        delegate :stamp, to: :class
      end
    RUBY
    write("app/host.rb", "class Host\n  include Mixin\nend\n")
    write("sig/generated/mixin.rbs", <<~RBS)
      module Mixin
        module ClassMethods
          def stamp: (String label, Integer times) -> String
        end
      end
    RBS
    write("sig/generated/host.rbs", "class Host\n  extend ::Mixin::ClassMethods\n  include Mixin\nend\n")

    rbs = RbsInfer::Analyzer.new(
      target_class: "Mixin", target_file: target, source_files: Dir["app/*.rb"]
    ).generate_rbs

    expect(rbs).to include("def stamp: (String label, Integer times) -> String")
  end

  # An overloaded target accepts several shapes, and the delegate accepts all of them.
  it "copies every overload the target declares" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        delegate :stamp, to: :printer

        def printer
          Printer.new
        end
      end
    RUBY
    write("app/printer.rb", "class Printer\n  def stamp(label)\n    label\n  end\nend\n")
    write("sig/generated/printer.rbs", <<~RBS)
      class Printer
        def stamp: (String label) -> String
                 | (Integer count) -> String
      end
    RBS

    expect(generate(target)).to include("def stamp: (String label) -> String | (Integer count) -> String")
  end

  # A target no declaration answers for keeps the empty list rather than inventing
  # one: the parameters arrive on the pass after, once its RBS exists.
  it "keeps an empty parameter list when nothing declares the target's method" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        delegate :stamp, to: :printer

        def printer
          Printer.new
        end
      end
    RUBY
    write("app/printer.rb", "class Printer\n  def stamp(label)\n    label\n  end\nend\n")

    expect(generate(target)).to include("def stamp: () ->")
  end

  # `allow_nil` still nilablizes the return, and only the return.
  it "nilablizes the return of a copied signature under allow_nil" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        delegate :stamp, to: :printer, allow_nil: true

        def printer
          Printer.new
        end
      end
    RUBY
    write("app/printer.rb", "class Printer\n  def stamp(label)\n    label\n  end\nend\n")
    write("sig/generated/printer.rbs", "class Printer\n  def stamp: (String label) -> String\nend\n")

    expect(generate(target)).to include("def stamp: (String label) -> String?")
  end
end
