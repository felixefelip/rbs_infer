# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A nested module is emitted inside its enclosing target's block rather than as a target
# of its own (felixefelip/rbs_infer#22), so ONE target holds the methods of all of them.
# Two nested modules declaring the same method name is therefore the normal case, and the
# inferred-parameter table keyed those methods by NAME alone: the first owner answered for
# every call, and the type read off one homonym's call sites was written onto the other's
# signature (felixefelip/rbs_infer#215).
RSpec.describe "two nested modules declaring the same method name" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # `Wrap` is a pure namespace, so its two nested modules are the whole membership —
  # `Alpha#stamp` and `Beta.stamp`, one name, two methods, different sides.
  def write_target
    write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Alpha
          def stamp(value)
            value
          end
        end

        module Beta
          def self.stamp(value)
            value
          end
        end
      end
    RUBY
  end

  # The previous pass's output: what types the caller's local as `singleton(Wrap::Beta)`.
  def write_signatures
    write("sig/generated/wrap.rbs", <<~RBS)
      class Wrap
        module Alpha
          def stamp: (untyped value) -> untyped
        end

        module Beta
          def self.stamp: (untyped value) -> untyped
        end
      end
    RBS
  end

  it "types the singleton the call reaches, and leaves its instance-side homonym alone" do
    target = write_target
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          klass = Wrap::Beta
          klass.stamp("hi")
        end
      end
    RUBY
    write_signatures

    rbs = RbsInfer::Analyzer.new(target_class: "Wrap", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    # `singleton(Wrap::Beta)` reaches `Beta.stamp` — the receiver names the owner and
    # the `singleton()` says which side of it.
    expect(rbs).to include("def self.stamp: (String value)")
    # And says nothing about `Alpha#stamp`, which no call site mentions. Under the
    # name-keyed table this line read `(String value)` too.
    expect(rbs).to include("def stamp: (untyped value)")
  end

  # The other side of the same table: a receiver that is a plain constant, which is how
  # `Example19::Responder.deny(...)` reaches a nested module (felixefelip/rbs_infer#159).
  # `resolve_receiver_type` returns the bare name there — it cannot say whether the call
  # is on the class object or on a value of that type — so both sides stay eligible.
  it "still types a nested module's singleton reached by a bare constant receiver" do
    target = write_target
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          Wrap::Beta.stamp("hi")
        end
      end
    RUBY
    write_signatures

    rbs = RbsInfer::Analyzer.new(target_class: "Wrap", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def self.stamp: (String value)")
  end
end
