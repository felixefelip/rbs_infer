# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "tempfile"
require "yaml"
require_relative "../support/steep_baseline_runner"

# Baseline-style steep check: runs `steep check` against the dummy app and
# compares the resulting error list to spec/expectations/steep_baseline.txt.
#
# - Fails if *any* error is in the current run but not in the baseline
#   (regression — guard against new type errors introduced by changes to
#   the generators, RBS shims, or the dummy fixtures).
# - Fails if any error is in the baseline but not in the current run
#   (improvement — forces the dev to consciously refresh the baseline so
#   we don't silently drift back into a worse state later).
#
# To accept changes in either direction:
#
#     UPDATE_STEEP_BASELINE=1 bundle exec rspec spec/integration/steep_dummy_spec.rb
RSpec.describe "Steep type check on dummy app", :dummy_app do
  let(:dummy_root) { Pathname.new(DUMMY_APP_ROOT) }
  let(:baseline_path) { Pathname.new(File.expand_path("../expectations/steep_baseline.txt", __dir__)) }
  let(:contracts_expectation_path) { Pathname.new(File.expand_path("../expectations/steep_contracts.yml", __dir__)) }

  before(:all) do
    Dir.chdir(DUMMY_APP_ROOT) do
      Bundler.with_unbundled_env do
        system("bundle", "install", "--quiet", exception: true)
        system("bundle", "exec", "rake", "db:create", "db:migrate", "RAILS_ENV=development",
               exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rake", "rbs_rails:all",
               exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rbs", "collection", "install",
               exception: true, out: File::NULL, err: File::NULL)
        # rbs_infer:carrierwave:all must run *after* rbs_rails:all because it
        # strips the column accessors from the freshly-generated rbs_rails
        # output. Skipping it would let the rbs_rails-emitted `def avatar:
        # () -> ::String?` clash with the uploader-typed accessor and surface
        # as a noisy DuplicateMethodDefinition.
        system("bundle", "exec", "rake", "rbs_infer:carrierwave:all",
               exception: true, out: File::NULL, err: File::NULL)
        # Also after rbs_rails:all: the Devise generator decorates `current_account`
        # with `Account::Validated` only when rbs_rails has already put that marker on
        # disk. Run earlier, the helpers silently degrade to a bare `Account`.
        system("bundle", "exec", "rake", "rbs_infer:devise:all",
               exception: true, out: File::NULL, err: File::NULL)
        # Concern/module `@type self:`/`@type instance:` now come from this
        # sidecar (felixefelip/rbs_infer#52); `steep check` reads it instead of
        # deriving names from paths. Without it, concern self-types regress.
        system("bundle", "exec", "rake", "rbs_infer:module_self_types:all",
               exception: true, out: File::NULL, err: File::NULL)
      end
    end
  end

  # `steep check` on the dummy takes ~35s and BOTH examples need its result — one reads
  # the sidecar it regenerates, the other its diagnostics. Run once and share.
  #
  # Memoized on the example GROUP, not in a `let` (per-example, so it would run twice) and
  # not in `before(:all)` (which would tie the two examples to one hook and re-run the
  # check for any future example that doesn't need it). Both examples observe the same
  # process, which is also more faithful than two runs: the sidecar checked below is
  # exactly the one the diagnostics were produced with.
  #
  # Safe to share because the run has no inputs either example varies — the dummy's files
  # are fixed by the `before(:all)` generator sweep above, and neither example writes to
  # them. `UPDATE_*` env vars only change what is done with the OUTPUT.
  #
  # The runner asks Steep to save its complete LSP diagnostic set as expectations instead
  # of parsing the human-readable formatter. That formatter can crash while rendering a
  # source excerpt; its stdout then contains only a valid-looking prefix of the errors.
  # The runner also requires a successful exit and a valid artifact before a refresh can
  # reach write_baseline, so partial output can never erase existing entries again.
  def self.steep_result
    @steep_result ||= SteepBaselineRunner.new(project_root: DUMMY_APP_ROOT).call
  end

  def run_steep
    self.class.steep_result
  end

  def load_baseline
    return [] unless baseline_path.exist?

    baseline_path.read.lines.map(&:chomp).reject(&:empty?)
  end

  def write_baseline(errors)
    baseline_path.parent.mkpath
    contents = errors.join("\n") + "\n"

    Tempfile.create(["steep_baseline", ".txt"], baseline_path.dirname) do |temporary|
      temporary.write(contents)
      temporary.flush
      temporary.fsync
      temporary.chmod(0o644)
      temporary.close
      File.rename(temporary.path, baseline_path)
    end
  end

  it "regenerates sig/generated/.steep_contracts.yml with the expected entries" do
    # Phase 2 of the Steep fork (felixefelip/steep#2) makes `steep check` regenerate
    # the contracts sidecar on every run. Compared to a checked-in expectation so
    # any new entry (or change in an existing one) is surfaced as a diff.
    #
    # To accept changes:
    #
    #     UPDATE_STEEP_CONTRACTS=1 bundle exec rspec spec/integration/steep_dummy_spec.rb
    run_steep

    sidecar_path = dummy_root.join("sig/generated/.steep_contracts.yml")
    expect(sidecar_path).to exist, "expected #{sidecar_path} to be regenerated by `steep check`"

    actual = sidecar_path.read

    if ENV["UPDATE_STEEP_CONTRACTS"]
      contracts_expectation_path.parent.mkpath
      contracts_expectation_path.write(actual)
      skip "contracts expectation refreshed at #{contracts_expectation_path.relative_path_from(Pathname.pwd)}"
    end

    expected = contracts_expectation_path.exist? ? contracts_expectation_path.read : ""
    expect(actual).to eq(expected),
                      "sidecar differs from expectation. Refresh with UPDATE_STEEP_CONTRACTS=1 if intended."
  end

  it "produces only the errors recorded in the baseline" do
    current = run_steep.diagnostics

    if ENV["UPDATE_STEEP_BASELINE"]
      write_baseline(current)
      skip "baseline refreshed at #{baseline_path.relative_path_from(Pathname.pwd)} (#{current.size} entries)"
    end

    baseline = load_baseline
    new_errors = current - baseline
    fixed_errors = baseline - current

    failures = []
    if new_errors.any?
      failures << "New steep errors not in baseline (regression):\n  " + new_errors.join("\n  ")
    end
    if fixed_errors.any?
      failures << "Errors gone from baseline (good — refresh with UPDATE_STEEP_BASELINE=1):\n  " + fixed_errors.join("\n  ")
    end

    expect(failures).to be_empty, failures.join("\n\n")
  end
end
