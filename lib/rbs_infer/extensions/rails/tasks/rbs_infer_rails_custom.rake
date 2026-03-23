# frozen_string_literal: true

require_relative "../custom_generator"

namespace :rbs_infer do
  namespace :rails_custom do
    desc "Generate RBS files for custom Rails types (ApplicationController, DeviseCustom, etc.)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      output_dir = File.join(app_dir, "sig/rbs_rails_custom")
      source_files = Dir[File.join(app_dir, "app/**/*.rb")]

      generator = RbsInfer::Extensions::Rails::CustomGenerator.new(
        output_dir: output_dir,
        app_dir: app_dir,
        source_files: source_files
      )
      generator.generate_all

      puts "Generated custom Rails RBS files in sig/rbs_rails_custom/"
    end
  end
end
