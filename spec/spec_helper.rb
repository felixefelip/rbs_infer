# frozen_string_literal: true

require "rbs_infer"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.exclude_pattern = ""
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Integration tests require PROJECT_ROOT pointing to a Rails project
  # Run with: PROJECT_ROOT=/path/to/project bundle exec rspec --tag integration
  config.filter_run_excluding :integration unless ENV["PROJECT_ROOT"]

  config.around(:each, :integration) do |example|
    project_root = ENV["PROJECT_ROOT"]
    if project_root && Dir.exist?(project_root)
      Dir.chdir(project_root) { example.run }
    else
      skip "Set PROJECT_ROOT to run integration tests"
    end
  end
end
