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

        # Drop the controller-ivar cache. Call between stabilization passes
        # so freshly-written RBS for controllers/helpers is re-read instead
        # of returning stale results computed from an incomplete env.
        def reset_cache!
          @erb_ivar_cache = nil
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
                # Key with the leading `@` so the caller-file analyzer
                # can distinguish ivar lookups (`@company`) from
                # local-var lookups (`company`) when both happen to
                # share a basename — common in views that iterate
                # `@companies.each |company|` and pass `company`
                # downstream. Without the `@`, the ivar's wide type
                # would be returned for any `company` local read.
                #
                # Strip the outer trailing `?` for the same reason the
                # ERB convention generator does (`unwrap_outer_nilable`
                # in controller_analyzer.rb): view templates only run
                # after the controller action, so an ivar declared
                # `T?` (because not written in `initialize`) is in
                # practice always set by the time the view passes it
                # to a helper. Keeping the `?` here leaks `nil` into
                # the helper body's parameter type and produces false
                # NoMethod errors for `param.foo` calls.
                ivar_types["@#{m[1]}"] = unwrap_outer_nilable(m[2])
              end
            end
            @erb_ivar_cache[cache_key] = ivar_types
          rescue
            @erb_ivar_cache[cache_key] = {}
          end
        end

        # Removes a single trailing `?` and balanced wrapping parens
        # from a type string. Mirrors the helper in
        # `controller_analyzer.rb` — see comment in `erb_ivar_types`
        # for the rationale.
        def unwrap_outer_nilable(type_str)
          return type_str unless type_str.is_a?(String) && type_str.end_with?("?")
          stripped = type_str.chomp("?")
          if stripped.start_with?("(") && stripped.end_with?(")") && balanced_outer_parens?(stripped)
            stripped[1..-2]
          else
            stripped
          end
        end

        def balanced_outer_parens?(str)
          return false unless str.start_with?("(") && str.end_with?(")")
          depth = 0
          str.each_char.with_index do |c, i|
            depth += 1 if c == "("
            depth -= 1 if c == ")"
            return false if depth.zero? && i < str.length - 1
          end
          depth.zero?
        end
      end
    end
  end
end
