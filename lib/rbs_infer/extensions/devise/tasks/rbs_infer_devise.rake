# frozen_string_literal: true

require_relative "../generator"
require_relative "../../rails/current_attributes_callbacks_generator"

namespace :rbs_infer do
  namespace :devise do
    desc "Generate RBS for Devise per-scope controller helpers (current_user, etc.)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd

      generator = RbsInfer::Extensions::Devise::Generator.new(
        app_dir: app_dir,
        output_dir: File.join(app_dir, "sig/rbs_infer_devise")
      )
      scopes = generator.generate_all

      if scopes.empty?
        puts "No devise_for declarations found in config/routes.rb — nothing generated."
        next
      end

      puts "Generated Devise scoped helpers RBS in sig/rbs_infer_devise/ (scopes: #{scopes.map { |s| s[:scope] }.join(", ")})"

      # CurrentAttributes consumer of the auth-layer facts: handlers that
      # populate globals (`Current.user = current_user`) under the guard
      # get their own markers + applies_constants sidecar, in a separate
      # sig dir — Current is not a Devise concern.
      # Same source universe the rest of rbs_infer resolves against, so
      # transitive-write types (`Current.caderneta = value.caderneta`)
      # match (felixefelip/rbs_infer#41).
      source_files = Dir[
        File.join(app_dir, "app/**/*.rb"),
        File.join(app_dir, "lib/**/*.rb"),
        File.join(app_dir, "engines/**/*.rb")
      ]

      current = RbsInfer::Extensions::Rails::CurrentAttributesCallbacksGenerator.new(
        app_dir: app_dir,
        output_dir: File.join(app_dir, "sig/rbs_infer_current_attributes"),
        scanner: generator.build_scanner(scopes),
        resource_types: generator.proven_resource_types(scopes),
        source_files: source_files
      )
      populated = current.generate_all

      unless populated.empty?
        consts = populated.map { |p| "#{p[:const_name]}.#{p[:attr]}" }.uniq.join(", ")
        puts "Generated CurrentAttributes callback narrowing in sig/rbs_infer_current_attributes/ (#{consts})"
      end
    end
  end
end
