# frozen_string_literal: true

require_relative "../current_attributes_runtime_generator"

namespace :rbs_infer do
  namespace :current_runtime do
    desc "Generate the CurrentAttributes-runtime pseudo-code sidecar for Steep (sig/generated/steep_current_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::CurrentAttributesRuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated CurrentAttributes-runtime pseudo-code: #{dir}"
    end
  end
end
