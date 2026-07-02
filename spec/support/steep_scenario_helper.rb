# frozen_string_literal: true

require "tmpdir"
require "open3"
require "pathname"

# End-to-end scenario helper for the rbs_infer → Steep pipeline.
#
# For each scenario it writes plain-Ruby source into an *isolated* temp
# project, generates the RBS with `rbs_infer`, runs a real `steep check`
# (which infers/enforces precondition contracts and type-checks), and returns
# the parsed diagnostics. Because every scenario is its own throwaway project,
# class names can be reused freely across examples without collisions — the
# reason to prefer this over adding fixtures to the shared dummy app.
#
# Both `rbs_infer` and `steep` are run through the repo's own Gemfile (steep is
# wired via `path:`), so the checks exercise the working-tree versions.
module SteepScenarioHelper
  # spec/support/ -> repo root
  GEMFILE = File.expand_path("../../Gemfile", __dir__)

  STEEP_ERROR_LINE =
    /\A(?<path>[^\s:]+\.[a-z]+):(?<line>\d+):(?<col>\d+):\s+\[(?<sev>error|warning)\]\s+(?<msg>.+)\z/

  Result = Struct.new(:diagnostics, :generated_rbs, :steep_output, keyword_init: true) do
    def clean?
      diagnostics.empty?
    end
  end

  # Generates RBS with rbs_infer and runs `steep check` on `ruby` in an
  # isolated temp project. Returns a Result with the parsed `diagnostics`
  # (sorted, unique), the `generated_rbs`, and the raw `steep_output`.
  def steep_scenario(ruby)
    Dir.mktmpdir("rbs-infer-scenario") do |dir|
      dir = Pathname(dir)
      (dir + "app").mkpath
      (dir + "app" + "scenario.rb").write(ruby)
      (dir + "Steepfile").write(<<~STEEP)
        target :app do
          signature "sig"
          check "app"
        end
      STEEP

      Bundler.with_unbundled_env do
        env = { "BUNDLE_GEMFILE" => GEMFILE }

        _out, gen_err, gen_status = Open3.capture3(
          env, "bundle", "exec", "rbs_infer", "app", "--output", "--output-dir", "sig/generated",
          chdir: dir.to_s
        )
        raise "rbs_infer failed:\n#{gen_err}" unless gen_status.success?

        steep_out, _err, _status = Open3.capture3(
          env, "bundle", "exec", "steep", "check",
          chdir: dir.to_s
        )

        Result.new(
          diagnostics: parse_steep_diagnostics(steep_out),
          generated_rbs: (dir + "sig" + "generated" + "app" + "scenario.rbs").read,
          steep_output: steep_out
        )
      end
    end
  end

  def parse_steep_diagnostics(output)
    output.lines.filter_map do |line|
      m = line.chomp.match(STEEP_ERROR_LINE) or next
      "#{m[:path]}:#{m[:line]}:#{m[:col]}: [#{m[:sev]}] #{m[:msg]}"
    end.sort.uniq
  end
end
