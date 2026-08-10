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

  # A constructor's arguments are collected by `extract_positional_args`, a different
  # path from every other method's — `initialize` is skipped by
  # `extract_target_method_params` and served by `init_positional_params` instead.
  it "types a constructor's splat from `.new` call sites" do
    rbs = rbs_for(
      "notifier.rb",
      "notifier.rb" => "class Notifier\n  def initialize(*recipients)\n    @recipients = recipients\n  end\nend\n",
      "caller.rb" => "class Caller\n  def go\n    Notifier.new(User.new, User.new)\n  end\nend\n\nclass User\nend\n"
    )

    expect(rbs).to include("def initialize: (*User recipients) ->")
  end

  it "keeps a constructor's leading params separate from its splat" do
    rbs = rbs_for(
      "notifier.rb",
      "notifier.rb" => "class Notifier\n  def initialize(subject, *bodies)\n    @subject = subject\n    @bodies = bodies\n  end\nend\n",
      "caller.rb" => "class Caller\n  def go\n    Notifier.new(\"hi\", 1, 2)\n  end\nend\n"
    )

    expect(rbs).to include("def initialize: (String subject, *Integer bodies) ->")
  end

  # The intra-class path (`IntraClassCallAnalyzer`) maps by index against its own
  # positional list, built the way `extract_target_method_params` used to be.
  it "types a splat called only from inside its own class" do
    rbs = rbs_for(
      "notifier.rb",
      "notifier.rb" => <<~RUBY,
        class Notifier
          def run
            internal(User.new, User.new)
          end

          def internal(*people)
            people
          end
        end
      RUBY
      "user.rb" => "class User\nend\n"
    )

    expect(rbs).to include("def internal: (*User people) ->")
  end

  it "unions an intra-class splat's arguments too" do
    rbs = rbs_for(
      "notifier.rb",
      "notifier.rb" => <<~RUBY
        class Notifier
          def run
            internal("a", 1)
          end

          def internal(*things)
            things
          end
        end
      RUBY
    )

    expect(rbs).to include("def internal: (*(String | Integer) things) ->")
  end

  it "stays untyped when no call site says anything" do
    rbs = rbs_for("notifier.rb", "notifier.rb" => "class Notifier\n  def notify(*recipients)\n    recipients\n  end\nend\n")

    expect(rbs).to include("def notify: (*untyped recipients) ->")
  end

  # The other direction: a splat in the ARGUMENTS, against a fixed parameter. It does not
  # place itself — `notify(*people)` may pass one argument or five — and what arrives is the
  # array's elements, never the array. Recording `Array[untyped]` was not imprecise but
  # wrong: `recipient` cannot receive an Array, and a wrong parameter type reads as an
  # answer where `untyped` reads as a question (felixefelip/rbs_infer#205).
  describe "a splat ARGUMENT against a fixed parameter" do
    it "says nothing, rather than handing the array to the parameter" do
      rbs = with_caller(
        "  def notify(recipient)\n    recipient\n  end",
        "    people = [User.new]\n    Notifier.new.notify(*people)"
      )

      expect(rbs).to include("def notify: (untyped recipient) ->")
      expect(rbs).not_to include("Array[")
    end

    it "does not place the arguments that follow it either" do
      rbs = with_caller(
        "  def notify(first, second)\n    [first, second]\n  end",
        "    rest = [User.new]\n    Notifier.new.notify(*rest, \"tail\")"
      )

      expect(rbs).to include("def notify: (untyped first, untyped second) ->")
    end

    it "still reads the arguments BEFORE it" do
      rbs = with_caller(
        "  def notify(first, second)\n    [first, second]\n  end",
        "    rest = [User.new]\n    Notifier.new.notify(\"head\", *rest)"
      )

      expect(rbs).to include("def notify: (String first, untyped second) ->")
    end

    it "leaves an intra-class call alone the same way" do
      rbs = rbs_for(
        "notifier.rb",
        "notifier.rb" => <<~RUBY
          class Notifier
            def run(*things)
              internal(*things)
            end

            def internal(thing)
              thing
            end
          end
        RUBY
      )

      expect(rbs).to include("def internal: (untyped thing) ->")
    end
  end
end
