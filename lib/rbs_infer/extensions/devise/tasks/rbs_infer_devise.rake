# frozen_string_literal: true

require_relative "../generator"

namespace :rbs_infer do
  namespace :devise do
    desc "Generate pseudo-code for Devise per-scope controller helpers (current_user, etc.)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      app_paths = RbsInfer::Extensions::Rails::AppPaths.current(app_dir)
      sidecar_dir = RbsInfer::Extensions::Devise::Generator::SIDECAR_DIR

      generator = RbsInfer::Extensions::Devise::Generator.new(
        app_dir: app_dir,
        app_paths: app_paths,
        output_dir: File.join(app_dir, sidecar_dir)
      )
      scopes = generator.generate_all

      if scopes.empty?
        puts "No devise_for declarations found in the routes — nothing generated."
        next
      end

      puts "Generated Devise scoped helpers pseudo-code in #{sidecar_dir}/ (scopes: #{scopes.map do |s|
        s[:scope]
      end.join(", ")})"
    end
  end
end
