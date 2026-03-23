# frozen_string_literal: true

require_relative "../generator"

namespace :rbs_infer do
  namespace :enumerize do
    desc "Generate RBS files for enumerize attributes"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      output_dir = File.join(app_dir, "sig/rbs_enumerize")

      generator = RbsInfer::Extensions::Enumerize::Generator.new(app_dir: app_dir, output_dir: output_dir)
      generator.generate_all

      puts "Generated enumerize RBS files in sig/rbs_enumerize/"
    end
  end
end
