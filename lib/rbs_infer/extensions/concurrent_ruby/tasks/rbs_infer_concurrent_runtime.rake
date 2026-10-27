# frozen_string_literal: true

require_relative "../runtime_generator"

namespace :rbs_infer do
  namespace :concurrent_runtime do
    desc "Transcribe the concurrent-ruby source Concurrent::Map runs (sig/generated/steep_concurrent_runtime/)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      dir = RbsInfer::Extensions::ConcurrentRuby::RuntimeGenerator.new(app_dir: app_dir).generate
      puts "Generated concurrent-ruby runtime source: #{dir}"
    end
  end
end
