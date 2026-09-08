# frozen_string_literal: true

require_relative "../active_job/runtime_generator"

namespace :rbs_infer do
  namespace :job_runtime do
    desc "Generate the ActiveJob-runtime pseudo-code sidecar for Steep (sig/generated/steep_activejob_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::ActiveJob::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated ActiveJob-runtime pseudo-code: #{dir}"
    end
  end
end
