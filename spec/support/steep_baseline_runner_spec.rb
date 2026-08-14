# frozen_string_literal: true

require "spec_helper"
require_relative "steep_baseline_runner"

RSpec.describe SteepBaselineRunner do
  Status = Struct.new(:success?, :exitstatus)

  subject(:runner) { described_class.new(project_root: DUMMY_APP_ROOT) }

  it "reads every diagnostic from Steep's completed expectations artifact" do
    allow(Open3).to receive(:capture3) do |*arguments, **options|
      expectations_argument = arguments.find { |argument| argument.to_s.start_with?("--save-expectations=") }
      expectations_path = Pathname(expectations_argument.delete_prefix("--save-expectations="))
      expectations_path.write(<<~YAML)
        ---
        - file: app/models/send_dispatch.rb
          diagnostics:
          - range:
              start:
                line: 119
                character: 39
              end:
                line: 119
                character: 42
            severity: ERROR
            message: Unexpected positional argument
            code: Ruby::UnexpectedPositionalArgument
          - range:
              start:
                line: 107
                character: 33
              end:
                line: 107
                character: 39
            severity: WARNING
            message: |-
              First line
              explanation omitted by the compact baseline
            code: Ruby::UnresolvedSend
      YAML

      expect(arguments).to include("--no-daemon", "--jobs=1")
      expect(options).to eq(chdir: DUMMY_APP_ROOT)
      ["complete output", "", Status.new(true, 0)]
    end

    expect(runner.call).to have_attributes(
      stdout: "complete output",
      diagnostics: [
        "app/models/send_dispatch.rb:107:33: [warning] First line",
        "app/models/send_dispatch.rb:119:39: [error] Unexpected positional argument"
      ]
    )
  end

  it "drops a fresh type variable's number, which is not part of its identity" do
    runner = described_class.new(project_root: DUMMY_APP_ROOT)

    expect(runner.send(:normalize_message, "as a block-pass-argument of type `^(::Module) -> U(243)`"))
      .to eq("as a block-pass-argument of type `^(::Module) -> U(_)`")
    expect(runner.send(:normalize_message, "Type `::Integer` does not have method `abs`"))
      .to eq("Type `::Integer` does not have method `abs`")
  end

  it "rejects a failed Steep process instead of accepting its partial stdout" do
    allow(Open3).to receive(:capture3).and_return([
      "app/models/example.rb:1:0: [error] partial",
      "IndexError: formatter crashed",
      Status.new(false, 2)
    ])

    expect { runner.call }
      .to raise_error(RuntimeError, /exit status 2; baseline was not updated.*formatter crashed/m)
  end

  it "rejects a successful process that did not produce the expectations artifact" do
    allow(Open3).to receive(:capture3).and_return(["", "", Status.new(true, 0)])

    expect { runner.call }
      .to raise_error(RuntimeError, /succeeded without writing .*baseline was not updated/)
  end
end
