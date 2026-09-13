# frozen_string_literal: true

require_relative "../action_text/runtime_generator"

namespace :rbs_infer do
  namespace :actiontext_runtime do
    desc "Generate the ActionText-runtime pseudo-code sidecar for Steep (sig/generated/steep_actiontext_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::Rails::ActionText::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated ActionText-runtime pseudo-code: #{dir}"
    end
  end
end
