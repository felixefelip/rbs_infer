# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

# `def render(target = nil)` has one call site nobody writes: the default. Call sites
# answer what a caller passes, the default answers what the method gets when nobody
# passes anything, and taking only the first emitted `?String target` for a parameter
# whose own declaration binds it to nil (felixefelip/rbs_infer#208).
#
# `initialize` already followed this rule (its nil defaults are widened alongside the
# call-site types); every other method did not, and only stayed sound because those
# parameters were `untyped` — which admits nil — until a call site typed them.
RSpec.describe "a parameter defaulting to nil" do
  include TempFileHelpers

  def rbs_for(target_body, run_body)
    with_temp_files(
      "notifier.rb" => "class Notifier\n#{target_body}\nend\n",
      "caller.rb" => "class Caller\n  def run\n#{run_body}\n  end\nend\n"
    ) do |_dir, paths|
      target_path = paths.find { |p| File.basename(p) == "notifier.rb" }
      RbsInfer::Analyzer.new(target_file: target_path, source_files: paths).generate_rbs
    end
  end

  it "stays nilable however non-nil every call site is" do
    rbs = rbs_for(
      "  def notify(message = nil)\n    message\n  end",
      "    Notifier.new.notify(\"hi\")"
    )

    expect(rbs).to include("def notify: (?String? message) ->")
  end

  it "applies to a keyword default too" do
    rbs = rbs_for(
      "  def notify(message: nil)\n    message\n  end",
      "    Notifier.new.notify(message: \"hi\")"
    )

    expect(rbs).to include("def notify: (?message: String?) ->")
  end

  # A default that is not nil says nothing about nil, and the parameter keeps exactly
  # what the call sites gave it.
  it "leaves a non-nil default alone" do
    rbs = rbs_for(
      "  def notify(message = \"\")\n    message\n  end",
      "    Notifier.new.notify(\"hi\")"
    )

    expect(rbs).to include("def notify: (?String message) ->")
  end

  # Nothing to widen while the parameter is `untyped`: it already admits nil, and
  # `untyped?` is not a spelling.
  it "leaves an untyped parameter alone" do
    rbs = rbs_for(
      "  def notify(message = nil)\n    message\n  end",
      "    Notifier.new"
    )

    expect(rbs).to include("def notify: (?untyped message) ->")
  end

  # A method inside a nested module has its parameters filed under TWO keys: an
  # owner-matched call site qualifies (`Wrap::Alpha#stamp`), and every other kind
  # of evidence stays under the bare name. Reading the two MERGES them into a new
  # hash, and the widening was written into that copy — dropped with it. Both
  # parameters below default to nil, both got a type, and neither widened
  # (felixefelip/rbs_infer#235).
  #
  # Which is why the flat cases above never showed it: a method with only one
  # entry is looked up and mutated in place.
  describe "on a method whose types are split across a qualified and a bare key" do
    around do |ex|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
    end
    before { RbsInfer::Signatures::RbsTypeLookup.reset! }

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    it "widens the parameter in each key that holds one" do
      # `message` comes from the bare call in `Beta`'s body, `value` from the
      # call whose receiver names `Beta` — which reaches `Alpha#stamp` through
      # the extend, so it is filed under the owner.
      target = write("app/wrap.rb", <<~RUBY)
        class Wrap
          module Alpha
            def stamp(value = nil, message: nil)
              [value, message]
            end
          end

          module Beta
            extend Wrap::Alpha

            stamp(message: "hi")
          end
        end
      RUBY
      write("app/caller.rb", <<~RUBY)
        class Caller
          def run
            klass = Wrap::Beta
            klass.stamp("hi")
          end
        end
      RUBY
      # The previous pass's output, which is what types the caller's local.
      write("sig/generated/wrap.rbs", <<~RBS)
        class Wrap
          module Alpha
            def stamp: (?untyped value, ?message: untyped) -> untyped
          end

          module Beta
            extend ::Wrap::Alpha
          end
        end
      RBS

      rbs = RbsInfer::Analyzer.new(target_class: "Wrap", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

      expect(rbs).to include("def stamp: (?String? value, ?message: String?) ->")
    end
  end
end
