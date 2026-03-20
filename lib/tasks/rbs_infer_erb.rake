# frozen_string_literal: true

require_relative "../rbs_infer/erb_convention_generator"

namespace :rbs_infer do
  namespace :erb do
    desc "Generate RBS classes for ERB templates (views and partials)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      output_dir = File.join(app_dir, "sig/rbs_infer_erb")

      generator = RbsInfer::ErbConvention::Generator.new(app_dir: app_dir, output_dir: output_dir)
      generator.generate_all

      puts "Generated ERB convention RBS files in sig/rbs_infer_erb/"
    end
  end
end
