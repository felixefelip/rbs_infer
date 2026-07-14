# frozen_string_literal: true

require_relative "../controllers/runtime_generator"

namespace :rbs_infer do
  namespace :controller_runtime do
    desc "Generate the controller-runtime pseudo-code sidecar for Steep (sig/generated/steep_controller_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated controller-runtime pseudo-code: #{dir}"
    end
  end
end
