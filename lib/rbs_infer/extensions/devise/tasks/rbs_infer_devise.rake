# frozen_string_literal: true

require_relative "../generator"

namespace :rbs_infer do
  namespace :devise do
    desc "Generate RBS for Devise per-scope controller helpers (current_user, etc.)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      output_dir = File.join(app_dir, "sig/rbs_infer_devise")

      generator = RbsInfer::Extensions::Devise::Generator.new(app_dir: app_dir, output_dir: output_dir)
      scopes = generator.generate_all

      if scopes.empty?
        puts "No devise_for declarations found in config/routes.rb — nothing generated."
      else
        puts "Generated Devise scoped helpers RBS in sig/rbs_infer_devise/ (scopes: #{scopes.map { |s| s[:scope] }.join(", ")})"
      end
    end
  end
end
