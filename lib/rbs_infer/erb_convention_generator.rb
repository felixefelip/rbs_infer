# frozen_string_literal: true

require "prism"
require "fileutils"
require_relative "../rbs_infer"

module RbsInfer
  module ErbConvention
    class Generator
      attr_reader :app_dir, :output_dir, :source_files

      def initialize(app_dir:, output_dir:, source_files: nil)
        @app_dir = app_dir
        @output_dir = output_dir
        @source_files = source_files || Dir[File.join(app_dir, "app/**/*.rb")]
      end

      def generate_all
        erb_files = Dir[File.join(@app_dir, "app/views/**/*.{html,turbo_stream}.erb")].sort
        erb_files.each { |erb_path| generate_for_erb(erb_path) }
      end

      private

      def generate_for_erb(erb_path)
        relative = erb_path.sub("#{@app_dir}/", "")
        view_relative = relative.sub(%r{\Aapp/views/}, "")
        class_name = erb_class_name(view_relative)
        return unless class_name

        view_info = parse_view_path(view_relative)
        ivar_types = {}

        if view_info
          controller_file = find_controller_file(view_info[:controller_name])
          if controller_file
            ivar_types = extract_action_ivars(
              controller_file,
              view_info[:controller_class],
              view_info[:action]
            )
          end
        end

        helpers = detect_helpers(view_info)
        rbs = build_rbs(class_name, ivar_types, helpers)

        output_subpath = relative.sub(/\.(html|turbo_stream)\.erb\z/, ".rbs")
        output_path = File.join(@output_dir, output_subpath)
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, rbs)
      end

      # Convert view relative path to ERB class name.
      #   "posts/show.html.erb"               → "ERBPostsShow"
      #   "posts/_form.html.erb"              → "ERBPartialPostsForm"
      #   "admin/posts/show.html.erb"         → "ERBAdminPostsShow"
      #   "layouts/application.html.erb"      → "ERBLayoutsApplication"
      #   "user_mailer/welcome.html.erb"      → "ERBUserMailerWelcome"
      def erb_class_name(view_relative)
        path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
        parts = path.split("/")
        filename = parts.pop
        return nil unless filename

        is_partial = filename.start_with?("_")
        filename = filename.sub(/\A_/, "") if is_partial

        segments = (parts + [filename]).map { |s| s.split(/[_-]/).map(&:capitalize).join }

        prefix = is_partial ? "ERBPartial" : "ERB"
        "#{prefix}#{segments.join}"
      end

      # Parse view path to extract controller class and action.
      # Returns nil for partials and layouts (no controller association).
      def parse_view_path(view_relative)
        path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
        parts = path.split("/")
        filename = parts.pop

        return nil if filename&.start_with?("_")
        return nil if parts.first == "layouts"
        return nil if parts.empty?

        controller_name = parts.join("/")
        controller_class = parts.map { |s| s.split(/[_-]/).map(&:capitalize).join }.join("::") + "Controller"

        { controller_name: controller_name, controller_class: controller_class, action: filename }
      end

      def find_controller_file(controller_name)
        file = File.join(@app_dir, "app/controllers/#{controller_name}_controller.rb")
        File.exist?(file) ? file : nil
      end

      # Extract only the ivars relevant to a specific controller action.
      def extract_action_ivars(controller_file, controller_class, action)
        all_ivar_types = controller_ivar_types(controller_file, controller_class)
        return {} if all_ivar_types.empty?

        source = File.read(controller_file)
        tree = Prism.parse(source).value

        ivar_method_map = map_ivars_to_methods(tree)
        relevant = relevant_methods_for_action(tree, action)

        filtered = {}
        all_ivar_types.each do |name, type|
          writers = ivar_method_map[name] || Set.new
          filtered[name] = type if writers.any? { |m| relevant.include?(m) }
        end
        filtered
      end

      # Generate controller RBS via Analyzer and extract ivar types (cached).
      def controller_ivar_types(controller_file, controller_class)
        @controller_ivar_cache ||= {}
        return @controller_ivar_cache[controller_class] if @controller_ivar_cache.key?(controller_class)

        rbs = RbsInfer::Analyzer.new(
          target_class: controller_class,
          target_file: controller_file,
          source_files: @source_files
        ).generate_rbs

        ivars = {}
        rbs&.each_line do |line|
          m = line.strip.match(/\A@(\w+): (.+)\z/)
          ivars[m[1]] = m[2] if m
        end

        @controller_ivar_cache[controller_class] = ivars
      end

      # Map ivar names to the set of methods that write them.
      def map_ivars_to_methods(tree)
        map = Hash.new { |h, k| h[k] = Set.new }
        each_def(tree) do |defn|
          method_name = defn.name.to_s
          each_ivar_write(defn) { |ivar_name| map[ivar_name] << method_name }
        end
        map
      end

      def each_def(node, &block)
        yield node if node.is_a?(Prism::DefNode)
        node.compact_child_nodes.each { |child| each_def(child, &block) }
      end

      def each_ivar_write(node, &block)
        case node
        when Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableOrWriteNode,
             Prism::InstanceVariableAndWriteNode,
             Prism::InstanceVariableOperatorWriteNode
          yield node.name.to_s.sub(/\A@/, "")
        end
        node.compact_child_nodes.each { |child| each_ivar_write(child, &block) }
      end

      # Compute the set of methods relevant to a given action:
      # the action itself + before_action callbacks that apply.
      def relevant_methods_for_action(tree, action)
        methods = Set.new([action])

        each_call(tree, :before_action) do |call|
          callback = extract_callback_name(call)
          next unless callback

          only = extract_action_filter(call, "only")
          except = extract_action_filter(call, "except")

          applies = if only
                      only.include?(action)
                    elsif except
                      !except.include?(action)
                    else
                      true
                    end

          methods << callback if applies
        end

        methods
      end

      def each_call(node, method_name, &block)
        yield node if node.is_a?(Prism::CallNode) && node.name == method_name
        node.compact_child_nodes.each { |child| each_call(child, method_name, &block) }
      end

      def extract_callback_name(call)
        arg = call.arguments&.arguments&.first
        arg.is_a?(Prism::SymbolNode) ? arg.value : nil
      end

      def extract_action_filter(call, key)
        call.arguments&.arguments&.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            next unless assoc.key.is_a?(Prism::SymbolNode) && assoc.key.value == key

            return extract_symbol_list(assoc.value)
          end
        end
        nil
      end

      def extract_symbol_list(node)
        case node
        when Prism::ArrayNode
          node.elements.filter_map { |e| e.is_a?(Prism::SymbolNode) ? e.value : nil }
        when Prism::SymbolNode
          [node.value]
        end
      end

      def detect_helpers(view_info)
        helpers = []

        if view_info
          helper_name = view_info[:controller_class].sub(/Controller\z/, "Helper")
          helper_path = "app/helpers/#{view_info[:controller_name]}_helper.rb"
          helpers << helper_name if File.exist?(File.join(@app_dir, helper_path))
        end

        app_helper = File.join(@app_dir, "app/helpers/application_helper.rb")
        helpers << "ApplicationHelper" if File.exist?(app_helper)

        helpers
      end

      def build_rbs(class_name, ivar_types, helpers)
        lines = ["# Generated by rbs_infer (erb_convention)", ""]
        lines << "class #{class_name}"

        ivar_types.each do |name, type|
          lines << "  @#{name}: #{type}"
        end

        helpers.each do |helper|
          lines << "  include #{helper}"
        end

        lines << "end"
        lines.join("\n") + "\n"
      end
    end
  end
end
