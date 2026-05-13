# frozen_string_literal: true

require_relative "../generator"

namespace :rbs_infer do
  namespace :carrierwave do
    desc "Generate RBS files for mount_uploader/mount_uploaders, stripping conflicting column accessors from sig/rbs_rails/"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      output_dir = File.join(app_dir, "sig/rbs_carrierwave")
      rbs_rails_dir = File.join(app_dir, "sig/rbs_rails")

      generator = RbsInfer::Extensions::CarrierWave::Generator.new(
        app_dir: app_dir,
        output_dir: output_dir,
        rbs_rails_dir: rbs_rails_dir
      )
      generator.generate_all

      puts "Generated carrierwave RBS files in sig/rbs_carrierwave/ (rbs_rails column accessors stripped)"
    end
  end
end
