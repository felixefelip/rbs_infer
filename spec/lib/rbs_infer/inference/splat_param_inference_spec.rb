# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

# A rest parameter used to be emitted as the bare string `"*untyped"`, with no name and no
# call-site lookup behind it — so `def notify(*recipients)` was `(*untyped)` however
# unambiguous the call sites were. Two halves were missing: the parameter was never offered
# as a slot (`extract_target_method_params` collected requireds, optionals and keywords
# only), and even offered it had no name for the type substitution, which is keyed by name,
# to fill.
RSpec.describe "rest parameter inference" do
  include TempFileHelpers

  def rbs_for(target, files)
    with_temp_files(files) do |_dir, paths|
      target_path = paths.find { |p| File.basename(p) == target }
      RbsInfer::Analyzer.new(target_file: target_path, source_files: paths).generate_rbs
    end
  end

  def with_caller(target_body, run_body)
    rbs_for(
      "notifier.rb",
      "notifier.rb" => "class Notifier\n#{target_body}\nend\n",
      "caller.rb" => "class Caller\n  def run\n#{run_body}\n  end\nend\n\nclass User\nend\n"
    )
  end

  it "types the splat from what the call sites pass" do
    rbs = with_caller(
      "  def notify(*recipients)\n    recipients\n  end",
      "    Notifier.new.notify(User.new, User.new)"
    )

    expect(rbs).to include("def notify: (*User recipients) ->")
  end

  # Every argument from the splat's position onward describes the SAME parameter, so they
  # are one union — not a race the first argument wins while the others fall off the end
  # of the parameter list.
  it "unions every argument the splat swallows, across call sites" do
    rbs = with_caller(
      "  def mixed(*things)\n    things\n  end",
      "    Notifier.new.mixed(User.new, \"text\")\n    Notifier.new.mixed(42)"
    )

    expect(rbs).to include("def mixed: (*(User | String | Integer) things) ->")
  end

  it "types the parameters before the splat by position, as before" do
    rbs = with_caller(
      "  def deliver(subject, *bodies)\n    [subject, bodies]\n  end",
      "    Notifier.new.deliver(\"hi\", \"a\", \"b\")"
    )

    expect(rbs).to include("def deliver: (String subject, *String bodies) ->")
  end

  it "keeps an optional before the splat separate from it" do
    rbs = with_caller(
      "  def only_optional(first = nil, *rest)\n    [first, rest]\n  end",
      "    Notifier.new.only_optional(\"a\", 1, 2)"
    )

    expect(rbs).to include("def only_optional: (?String first, *Integer rest) ->")
  end

  # Keywords are matched by name, and the splat does not eat them: `mode:` still lands on
  # `mode` even though it is written after arguments the splat took.
  it "leaves keywords after the splat to their own names" do
    rbs = with_caller(
      "  def with_keyword(*items, mode:)\n    [items, mode]\n  end",
      "    Notifier.new.with_keyword(User.new, User.new, mode: \"fast\")"
    )

    expect(rbs).to include("def with_keyword: (*User items, mode: String) ->")
  end

  # An anonymous `*` has no name for the substitution to key on, so it keeps the bare form
  # rather than inventing one.
  it "leaves an anonymous splat as `*untyped`" do
    rbs = with_caller(
      "  def anonymous(*)\n    1\n  end",
      "    Notifier.new.anonymous(User.new)"
    )

    expect(rbs).to include("def anonymous: (*untyped) ->")
  end

  it "stays untyped when no call site says anything" do
    rbs = rbs_for("notifier.rb", "notifier.rb" => "class Notifier\n  def notify(*recipients)\n    recipients\n  end\nend\n")

    expect(rbs).to include("def notify: (*untyped recipients) ->")
  end
end
