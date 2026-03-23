# frozen_string_literal: true

module RbsInfer
  module Extensions
    module Rails
      # Provides ERB view scanning as additional caller sources for the Analyzer.
      # This allows the core Analyzer to infer helper method param types from
      # ERB view usage without hardcoding any Rails-specific logic.
      #
      # Usage:
      #   resolver = ErbCallerResolver.new(app_dir: Rails.root.to_s, source_files: Dir["app/**/*.rb"])
      #   RbsInfer::Analyzer.new(
      #     target_class: "PostsHelper",
      #     target_file: "app/helpers/posts_helper.rb",
      #     source_files: source_files,
      #     extra_caller_sources: resolver
      #   )
      class ErbCallerResolver
        def initialize(app_dir:, source_files:)
          @app_dir = app_dir
          @source_files = source_files
        end

        # Called by Analyzer#infer_method_param_types_from_callers to provide
        # additional caller analysis from ERB views.
        def call(analyzer, target_class, source_files)
          return unless target_class.end_with?("Helper")

          scan_erb_views_for_helper_calls(analyzer, target_class, source_files)
        end

        private

        def scan_erb_views_for_helper_calls(analyzer, target_class, source_files)
          erb_files = Dir[File.join(@app_dir, "app/views/**/*.{html,turbo_stream}.erb")].sort
          return if erb_files.empty?

          controller_name = target_class.sub(/Helper\z/, "").gsub("::", "/")
          controller_name = controller_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

          erb_files.each do |erb_path|
            relative = erb_path.sub("#{@app_dir}/app/views/", "")

            unless target_class == "ApplicationHelper"
              view_controller = relative.split("/")[0..-2].join("/")
              next unless view_controller == controller_name || relative.start_with?("layouts/") || relative.include?("/_")
            end

            erb_source = File.read(erb_path)
            ruby_source = erb_to_ruby_safe(erb_source)
            next unless ruby_source

            local_var_types = erb_ivar_types(relative, source_files)

            analyzer.analyze_source(ruby_source, local_var_types: local_var_types)
          end
        rescue => e
          nil
        end

        def erb_to_ruby_safe(erb_source)
          require "herb"
          Herb.extract_ruby(erb_source, comments: true)
        rescue
          nil
        end

        def erb_ivar_types(view_relative, source_files)
          parts = view_relative.split("/")
          filename = parts.last.sub(/\.(html|turbo_stream)\.erb\z/, "")

          return {} if filename.start_with?("_")

          controller_parts = parts[0..-2]
          controller_name = controller_parts.join("/")
          controller_class = controller_parts.map { |p| p.split(/[_-]/).map(&:capitalize).join }.join("::") + "Controller"
          action = filename

          controller_file = Dir[File.join(@app_dir, "app/controllers/#{controller_name}_controller.rb")].first
          return {} unless controller_file && File.exist?(controller_file)

          @erb_ivar_cache ||= {}
          cache_key = "#{controller_class}##{action}"
          return @erb_ivar_cache[cache_key] if @erb_ivar_cache.key?(cache_key)

          begin
            ctrl_analyzer = RbsInfer::Analyzer.new(
              target_class: controller_class,
              target_file: controller_file,
              source_files: source_files
            )
            rbs = ctrl_analyzer.generate_rbs
            return(@erb_ivar_cache[cache_key] = {}) unless rbs

            ivar_types = {}
            rbs.each_line do |line|
              stripped = line.strip
              if (m = stripped.match(/\A@(\w+): (.+)\z/))
                ivar_types[m[1]] = m[2]
              end
            end
            @erb_ivar_cache[cache_key] = ivar_types
          rescue
            @erb_ivar_cache[cache_key] = {}
          end
        end
      end
    end
  end
end
