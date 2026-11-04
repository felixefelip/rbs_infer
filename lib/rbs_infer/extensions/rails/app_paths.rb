# frozen_string_literal: true

module RbsInfer
  module Extensions
    module Rails
      class AppPaths
        APP = "app"

        def self.conventional(app_dir)
          new { |key| [File.join(app_dir, key)] }
        end

        def self.of(application)
          paths = application.paths
          app_roots = paths[APP].paths.map(&:to_s)

          new do |key|
            registered = paths[key]
            if registered
              registered.paths.map(&:to_s)
            elsif key.start_with?("#{APP}/")
              app_roots.map { |root| File.join(root, key.delete_prefix("#{APP}/")) }
            else
              []
            end
          end
        end

        def self.current(app_dir)
          application = defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
          application ? of(application) : conventional(app_dir)
        end

        def initialize(&roots_for)
          @roots_for = roots_for
          @roots = {}
        end

        def roots(key)
          @roots[key] ||= @roots_for.call(key).uniq.select { |root| File.directory?(root) }
        end

        def glob(key, pattern)
          roots(key).flat_map { |root| Dir.glob(File.join(root, pattern)) }.sort
        end

        def files(key, pattern)
          found = {}
          roots(key).each do |root|
            Dir.glob(File.join(root, pattern)).each do |path|
              found[path.delete_prefix("#{root}/")] ||= path
            end
          end
          found.sort.to_h
        end

        def find(key, relative)
          roots(key).map { |root| File.join(root, relative) }.find { |path| File.exist?(path) }
        end
      end
    end
  end
end
