# frozen_string_literal: true

require_relative "../generator"

namespace :rbs_infer do
  namespace :devise do
    desc "Generate pseudo-code for Devise per-scope controller helpers (current_user, etc.)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      sidecar_dir = RbsInfer::Extensions::Devise::Generator::SIDECAR_DIR

      generator = RbsInfer::Extensions::Devise::Generator.new(
        app_dir: app_dir,
        output_dir: File.join(app_dir, sidecar_dir)
      )
      scopes = generator.generate_all

      if scopes.empty?
        puts "No devise_for declarations found in config/routes.rb — nothing generated."
        next
      end

      puts "Generated Devise scoped helpers pseudo-code in #{sidecar_dir}/ (scopes: #{scopes.map { |s| s[:scope] }.join(", ")})"
    end
  end
end
