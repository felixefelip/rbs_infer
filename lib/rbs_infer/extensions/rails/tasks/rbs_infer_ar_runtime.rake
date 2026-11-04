# frozen_string_literal: true

require_relative "../active_record/runtime_generator"

namespace :rbs_infer do
  namespace :ar_runtime do
    desc "Generate the AR-runtime pseudo-code sidecar for Steep (sig/generated/.steep_ar_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      app_paths = RbsInfer::Extensions::Rails::AppPaths.current(app_dir)
      generator = RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator.new(
        app_dir: app_dir,
        app_paths: app_paths
      )
      dir = generator.generate
      puts "Generated AR-runtime pseudo-code: #{dir}"
    end
  end
end
