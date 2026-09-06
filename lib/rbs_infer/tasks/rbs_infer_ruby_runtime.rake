# frozen_string_literal: true

require_relative "../project/ruby_runtime_generator"

namespace :rbs_infer do
  namespace :ruby_runtime do
    desc "Generate the language-runtime pseudo-code sidecar for Steep (sig/generated/steep_ruby_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Project::RubyRuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated language-runtime pseudo-code: #{dir}"
    end
  end
end
