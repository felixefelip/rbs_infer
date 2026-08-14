# frozen_string_literal: true

require "open3"
require "pathname"
require "tmpdir"
require "yaml"

# Runs Steep through its machine-readable expectations output. Parsing the
# human-readable formatter is unsafe here: if that formatter crashes halfway
# through the diagnostic list, its stdout is a valid-looking but truncated
# prefix that must never be allowed to replace the baseline.
class SteepBaselineRunner
  Result = Data.define(:diagnostics, :stdout)

  SEVERITIES = {
    "ERROR" => "error",
    "WARNING" => "warning"
  }.freeze

  def initialize(project_root:)
    @project_root = Pathname(project_root)
  end

  def call
    Dir.mktmpdir("rbs-infer-steep-baseline") do |directory|
      expectations_path = Pathname(directory).join("diagnostics.yml")
      stdout, stderr, status = run_steep(expectations_path)

      unless status.success?
        raise <<~MESSAGE
          `steep check` failed with exit status #{status.exitstatus}; baseline was not updated.

          stdout:
          #{stdout}

          stderr:
          #{stderr}
        MESSAGE
      end

      unless expectations_path.file?
        raise "`steep check` succeeded without writing #{expectations_path}; baseline was not updated."
      end

      Result.new(diagnostics: parse_expectations(expectations_path), stdout: stdout)
    end
  end

  private

  attr_reader :project_root

  def run_steep(expectations_path)
    env = {
      "STEEP_ERB_CONVENTION" => "1",
      "STEEP_MODULE_CONVENTION" => "1"
    }

    Bundler.with_unbundled_env do
      Open3.capture3(
        env,
        "bundle", "exec", "steep", "check",
        "--no-daemon", "--jobs=1", "--save-expectations=#{expectations_path}",
        chdir: project_root.to_s
      )
    end
  end

  def parse_expectations(path)
    entries = YAML.safe_load(path.read, aliases: false)
    raise "Steep wrote an invalid expectations document to #{path}" unless entries.is_a?(Array)

    entries.flat_map do |entry|
      file = entry.fetch("file")

      entry.fetch("diagnostics").map do |diagnostic|
        start = diagnostic.fetch("range").fetch("start")
        severity = SEVERITIES.fetch(diagnostic.fetch("severity"))
        message = normalize_message(diagnostic.fetch("message").lines.first.chomp)

        "#{file}:#{start.fetch("line")}:#{start.fetch("character")}: [#{severity}] #{message}"
      end
    end.sort.uniq
  end

  # A fresh type variable is numbered from a counter that spans the whole check,
  # so `U(243)` becomes `U(257)` when an unrelated file starts inferring more —
  # a baseline diff that says nothing happened. The identity is what matters
  # here and the number is not part of it, so drop it.
  FRESH_TYPE_VARIABLE = /\b([A-Z])\(\d+\)/

  def normalize_message(message)
    message.gsub(FRESH_TYPE_VARIABLE, '\1(_)')
  end
end
