# frozen_string_literal: true

require_relative "../views/runtime_generator"

namespace :rbs_infer do
  namespace :actionview_runtime do
    desc "Generate the view-runtime pseudo-code sidecar for Steep (sig/generated/steep_actionview_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::Views::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated view-runtime pseudo-code: #{dir}"
    end
  end
end
