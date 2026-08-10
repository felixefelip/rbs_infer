# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

# `recv.send(:stamp, "post")` passes `"post"` to `stamp`'s first parameter as surely as
# `recv.stamp("post")` does, and nothing about it is undecidable — the name is right there.
# Two halves were missing (felixefelip/rbs_infer#205): `SourceIndex` indexed such a file
# under `send`, a name no caller asks about, so the file was never opened as a caller; and
# even opened, `NewCallCollector` read a call to `send` whose first argument was a symbol.
#
# The half a checker cannot cover for us: felixefelip/steep#137 made Steep resolve these
# calls, which gave the CALLER's return types for free. A parameter is the other direction —
# it is inferred FROM call sites, and finding them is this repo's job.
RSpec.describe "send as a call site" do
  include TempFileHelpers

  def rbs_for(target, files)
    with_temp_files(files) do |_dir, paths|
      target_path = paths.find { |p| File.basename(p) == target }
      RbsInfer::Analyzer.new(target_file: target_path, source_files: paths).generate_rbs
    end
  end

  def with_caller(target_body, run_body)
    rbs_for(
      "stamper.rb",
      "stamper.rb" => "class Stamper\n#{target_body}\nend\n",
      "caller.rb" => "class Caller\n  def run\n#{run_body}\n  end\nend\n"
    )
  end

  it "types the parameter from what the send passes" do
    rbs = with_caller(
      "  def stamp(value)\n    \"stamped: #{'#{value}'}\"\n  end",
      "    Stamper.new.send(:stamp, \"post\")"
    )

    expect(rbs).to include("def stamp: (String value) ->")
  end

  # The reason a real app writes `send` at all, and the reason this was worth doing: reaching
  # past `private` is exactly where a method has no other call site to be inferred from.
  it "reaches a private method" do
    rbs = with_caller(
      "  private\n\n  def stamp(value)\n    value\n  end",
      "    Stamper.new.send(:stamp, \"post\")"
    )

    expect(rbs).to include("def stamp: (String value) ->")
  end

  # One dispatch, three spellings. `__send__` is the one a defensive library uses precisely
  # because `send` can be overridden, and a string names a method as well as a symbol.
  {
    "send with a symbol" => "send(:stamp, \"post\")",
    "send with a string" => "send(\"stamp\", \"post\")",
    "__send__" => "__send__(:stamp, \"post\")",
    "public_send" => "public_send(:stamp, \"post\")",
    "without parentheses" => "send :stamp, \"post\""
  }.each do |name, spelling|
    it "reads #{name}" do
      rbs = with_caller(
        "  def stamp(value)\n    value\n  end",
        "    Stamper.new.#{spelling}"
      )

      expect(rbs).to include("def stamp: (String value) ->")
    end
  end

  # The limit case: the name is a value, so no static analysis decides which method it is.
  # Attributing the argument to *some* method would be a guess, and a wrong parameter type
  # is worse than `untyped` — it is an answer.
  it "reads nothing from a computed name" do
    rbs = with_caller(
      "  def stamp(value)\n    value\n  end",
      "    name = :stamp\n    Stamper.new.send(name, \"post\")"
    )

    expect(rbs).to include("def stamp: (untyped value) ->")
  end

  it "reads nothing from an interpolated symbol" do
    rbs = with_caller(
      "  def stamp(value)\n    value\n  end",
      "    part = \"amp\"\n    Stamper.new.send(:\"st#{'#{part}'}\", \"post\")"
    )

    expect(rbs).to include("def stamp: (untyped value) ->")
  end

  it "unions what several sends pass, like any other call site" do
    rbs = with_caller(
      "  def stamp(value)\n    value\n  end",
      "    Stamper.new.send(:stamp, \"post\")\n    Stamper.new.send(:stamp, 42)"
    )

    expect(rbs).to match(/def stamp: \(\((String \| Integer|Integer \| String)\) value\) ->/)
  end

  it "carries keyword arguments through" do
    rbs = with_caller(
      "  def stamp(value:)\n    value\n  end",
      "    Stamper.new.send(:stamp, value: \"post\")"
    )

    expect(rbs).to include("def stamp: (value: String) ->")
  end

  # The desugared node is an ordinary call, so the rest-param folding from #201 applies to it
  # without knowing anything about `send`.
  it "folds into a rest parameter" do
    rbs = with_caller(
      "  def stamp(*values)\n    values\n  end",
      "    Stamper.new.send(:stamp, \"a\", \"b\")"
    )

    expect(rbs).to include("def stamp: (*String values) ->")
  end

  # The boundary, and the reason it needs no send-specific handling: a splat argument does
  # not place itself, so the desugared call says exactly what the direct spelling says —
  # nothing. Both go through the same mapper.
  it "says nothing when the send passes a splat" do
    rbs = with_caller(
      "  def stamp(value)\n    value\n  end",
      "    args = [\"post\"]\n    Stamper.new.send(:stamp, *args)"
    )

    expect(rbs).to include("def stamp: (untyped value) ->")
  end

  # A `send` the receiver declares itself — `Ractor#send`, a socket's, a message bus's — is
  # an ordinary method whose first argument is a VALUE. Reading it as a name would invent a
  # call that is not there, and lose the one that is.
  it "leaves a receiver's own send alone" do
    rbs = rbs_for(
      "bus.rb",
      "bus.rb" => "class Bus\n  def send(channel, payload)\n    [channel, payload]\n  end\n\n" \
                  "  def notify(text)\n    text\n  end\nend\n",
      "caller.rb" => "class Caller\n  def run\n    Bus.new.send(:notify, \"payload\")\n  end\nend\n"
    )

    expect(rbs).to include("def send: (Symbol channel, String payload) ->")
    expect(rbs).to include("def notify: (untyped text) ->")
  end

  # A bare `send(:helper, x)` inside the class is the same call, and the commonest reason to
  # write it there is that `helper` is private — the very methods
  # `IntraClassCallAnalyzer` exists to type.
  it "reads a bare send inside the class" do
    rbs = rbs_for(
      "stamper.rb",
      "stamper.rb" => <<~RUBY
        class Stamper
          def run
            send(:stamp, "post")
          end

          private

          def stamp(value)
            value
          end
        end
      RUBY
    )

    expect(rbs).to include("def stamp: (String value) ->")
  end
end
