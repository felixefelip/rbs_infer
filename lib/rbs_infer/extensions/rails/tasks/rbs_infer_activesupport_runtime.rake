# frozen_string_literal: true

require_relative "../active_support/runtime_generator"

namespace :rbs_infer do
  namespace :activesupport_runtime do
    desc "Generate the ActiveSupport-runtime pseudo-code sidecar for Steep (sig/generated/steep_activesupport_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::ActiveSupport::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated ActiveSupport-runtime pseudo-code: #{dir}"
    end
  end
end
