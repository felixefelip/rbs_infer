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
end
