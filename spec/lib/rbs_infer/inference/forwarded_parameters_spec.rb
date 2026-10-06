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
  #
  # Pending on the checker: in `!_.nil? || …` the falsy side of `!_.nil?`
  # narrows `_` to `nil` even where `_` cannot be nil (a `Printer`), so the
  # `if` body sees `(Printer | nil)` and the call is rejected. The right
  # narrowing there is `bot`. Once it is, this passes, and `pending` fails to
  # say so.
  it "returns the call's value or nil where the body can end without it" do
    pending "steep: `x.nil?` narrows a non-nilable `x` to nil instead of bot"
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

    expect(generate(target)).to include("def stamp: (String label, ?Integer times) -> String?")
  end

  # A receiver that may be nil is rejected whole by the checker, and nothing
  # reads past it: the method keeps what `...` accepts in general until a
  # caller establishes the receiver — the precondition the checker infers
  # from that rejection, enforced at the call sites.
  it "accepts anything while the receiver may be nil" do
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

    expect(generate(target)).to include("def stamp: (*untyped, **untyped) ?{ (*untyped) -> untyped } ->")
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
