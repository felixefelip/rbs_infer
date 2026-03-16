# frozen_string_literal: true

require_relative "../rbs_enumerize"

namespace :rbs_enumerize do
  desc "Generate RBS files for enumerize attributes"
  task :all do
    app_dir = Rails.root.to_s
    output_dir = Rails.root.join("sig/rbs_enumerize").to_s

    generator = RbsEnumerize::Generator.new(app_dir: app_dir, output_dir: output_dir)
    generator.generate_all

    puts "Generated enumerize RBS files in sig/rbs_enumerize/"
  end
end
