# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A method whose parameter list is `...` accepts what the method it forwards to
# accepts. That is the rule `delegate` was read by when the core read the macro
# (felixefelip/rbs_infer#294); ActiveSupport writes `def name(...)` and the
# forwarding call, so it is now the rule for the method itself — the parameters
# live in the forwarded method's declaration, and the checker says which method
# the call reaches (felixefelip/rbs_infer#355).
RSpec.describe "a method that forwards `...`" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def generate(target, target_class: "Target")
    RbsInfer::Analyzer.new(
      target_class: target_class, target_file: target, source_files: Dir["app/*.rb"]
    ).generate_rbs
  end

  # `printer`'s type is the previous pass's answer, as for every cross-file
  # type here: the run that first sees `Target` has no RBS for it yet, and the
  # forwarding call resolves on the pass after.
  before do
    write("app/printer.rb", "class Printer\n  def stamp(label, times = 1)\n    label\n  end\nend\n")
    write("sig/generated/printer.rbs", "class Printer\n  def stamp: (String label, ?Integer times) -> String\nend\n")
    write("sig/generated/target.rbs", "class Target\n  def printer: () -> Printer\nend\n")
  end

  it "takes the parameter list of the method it forwards to" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new

        def stamp(...)
          printer.stamp(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String")
  end

  # ActiveSupport's shape: the receiver is read into `_` first, an ordinary
  # local to the checker (felixefelip/steep#202).
  it "follows the receiver through a local" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new

        def stamp(...)
          _ = printer
          _.stamp(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String")
  end

  # `to: :class`: the call is made on the target's own class object.
  it "reaches a class method through `self.class`" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def self.stamp(label, times)
          label
        end

        def stamp(...)
          (self.class).stamp(...)
        end
      end
    RUBY
    write("sig/generated/target.rbs", "class Target\n  def self.stamp: (String label, Integer times) -> String\nend\n")

    expect(generate(target)).to include("def stamp: (String label, Integer times) -> String")
  end

  it "takes every overload the forwarded method declares" do
    write("sig/generated/printer.rbs", <<~RBS)
      class Printer
        def stamp: (String label) -> String
                 | (Integer count) -> String
      end
    RBS
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new

        def stamp(...)
          printer.stamp(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label) -> String | (Integer count) -> String")
  end

  # ActiveSupport's shape without `allow_nil:`. The receiver cannot be nil, so
  # the checker resolves the call and types the body: a `rescue` that only
  # raises adds nothing to its value.
  it "returns what the checker types the body as" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new

        def stamp(...)
          _ = printer
          _.stamp(...)
        rescue NoMethodError => e
          if _.nil?
            raise ArgumentError, "printer is nil"
          else
            raise
          end
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String")
  end

  # `allow_nil: true`: the call, or nothing — the `if` the body ends on.
  # NilClass has no `stamp`, so `nil.respond_to?(:stamp)` is `false` and the
  # condition is `!_.nil?`, narrowed by the checker as written
  # (felixefelip/rbs_infer#393). `printer` cannot be nil, so the body always
  # makes the call.
  it "returns the call's value where the receiver cannot be nil" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new

        def stamp(...)
          _ = printer
          if !_.nil? || nil.respond_to?(:stamp)
            _.stamp(...)
          end
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String\n")
  end

  it "returns the call's value or nil where the receiver may be nil" do
    write("sig/generated/target.rbs", "class Target\n  def printer: () -> Printer?\nend\n")
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = (Printer.new if rand > 0.5)

        def stamp(...)
          _ = printer
          if !_.nil? || nil.respond_to?(:stamp)
            _.stamp(...)
          end
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String?")
  end

  # A receiver that may be nil is rejected by the checker, and the call
  # reaches what any call on a nilable receiver reaches: `Printer` — nil has
  # no `stamp`, so that branch raises and adds no value. The `rescue` that only
  # raises adds none either.
  it "reaches what a call on a nilable receiver reaches" do
    write("sig/generated/target.rbs", "class Target\n  def printer: () -> Printer?\nend\n")
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = (Printer.new if rand > 0.5)

        def stamp(...)
          _ = printer
          _.stamp(...)
        rescue NoMethodError => e
          raise
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String")
  end

  # Where nil HAS the method, its branch is ordinary code, and no one
  # receiver's parameters are the call's.
  it "accepts anything where nil has the method too" do
    write("sig/generated/printer.rbs", "class Printer\n  def to_s: (Integer pad) -> String\nend\n")
    write("sig/generated/target.rbs", "class Target\n  def printer: () -> Printer?\nend\n")
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = (Printer.new if rand > 0.5)

        def to_s(...)
          _ = printer
          _.to_s(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def to_s: (*untyped, **untyped) ?{ (*untyped) -> untyped } ->")
  end

  # Without a declaration to read, `...` stays what it accepts in general —
  # positionals and keywords and a block. It used to come out as `(**untyped)`,
  # which rejects the positional arguments `...` exists to pass.
  it "accepts anything when the forwarded method is not declared" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def stamp(...)
          unknown.stamp(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (*untyped, **untyped) ?{ (*untyped) -> untyped } ->")
  end

  # Two calls to two methods accept two lists, and nothing picks one.
  it "accepts anything when the forwarding calls reach different methods" do
    write("sig/generated/other.rbs", "class Other\n  def stamp: (Integer count) -> String\nend\n")
    write("sig/generated/target.rbs", "class Target\n  def printer: () -> Printer\n  def other: () -> Other\nend\n")
    target = write("app/target.rb", <<~RUBY)
      class Target
        def printer = Printer.new
        def other = Other.new

        def stamp(...)
          printer.stamp(...)
          other.stamp(...)
        end
      end
    RUBY

    expect(generate(target)).to include("def stamp: (*untyped, **untyped) ?{ (*untyped) -> untyped } ->")
  end
end
