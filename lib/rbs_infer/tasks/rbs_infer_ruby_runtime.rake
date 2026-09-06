# frozen_string_literal: true

require_relative "../project/ruby_runtime_generator"

namespace :rbs_infer do
  namespace :ruby_runtime do
    desc "Generate the language-runtime pseudo-code sidecar for Steep (sig/generated/steep_ruby_runtime/)"
    task :all do
      dir = RbsInfer::Project::RubyRuntimeGenerator.new(app_dir: Rails.root.to_s).generate
      puts "Generated language-runtime pseudo-code: #{dir}"
    end
  end
end
