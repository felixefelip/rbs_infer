# frozen_string_literal: true

require_relative "../active_record/runtime_generator"

namespace :rbs_infer do
  namespace :ar_runtime do
    desc "Generate the AR-runtime pseudo-code sidecar for Steep (sig/generated/.steep_ar_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated AR-runtime pseudo-code: #{dir}"
    end
  end
end
