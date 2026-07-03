# frozen_string_literal: true

require_relative "../belongs_to_default_generator"

namespace :rbs_infer do
  namespace :belongs_to_default do
    desc "Generate the belongs_to-default expansion + source-map sidecars for Steep (sig/generated/.steep_belongs_to_default.{rb,yml})"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      expanded, sidecar = RbsInfer::Extensions::Rails::BelongsToDefaultGenerator.new(app_dir: app_dir).generate
      puts "Generated belongs_to-default expansion: #{expanded}"
      puts "Generated belongs_to-default source-map: #{sidecar}"
    end
  end
end
