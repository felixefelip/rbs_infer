# frozen_string_literal: true

require_relative "../active_record/belongs_to_default_generator"

namespace :rbs_infer do
  namespace :belongs_to_default do
    desc "Generate the belongs_to-default expansion dir + source-map sidecar for Steep (sig/generated/.steep_belongs_to_default[.yml])"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      expanded_dir, sidecar = RbsInfer::Extensions::Rails::ActiveRecord::BelongsToDefaultGenerator.new(app_dir: app_dir).generate
      puts "Generated belongs_to-default expansion dir: #{expanded_dir}"
      puts "Generated belongs_to-default source-map: #{sidecar}"
    end
  end
end
