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

        # Phase 1: collect partial locals from render call sites
        @partial_locals = collect_partial_locals(erb_files)

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
        local_types = {}

        if view_info
          controller_file = find_controller_file(view_info[:controller_name])
          if controller_file
            ivar_types = extract_action_ivars(
              controller_file,
              view_info[:controller_class],
              view_info[:action]
            )
          end
        else
          # Partial: resolve locals from render call sites
          partial_key = partial_key_from_view_relative(view_relative)
          local_types = @partial_locals[partial_key] || {} if partial_key
        end

        helpers = detect_helpers(view_info)
        helper_methods = collect_helper_methods(view_info)
        rbs = build_rbs(class_name, ivar_types, local_types, helpers, helper_methods)

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

      # Extract the partial key from a view-relative path.
      # "posts/_form.html.erb" → "posts/form"
      def partial_key_from_view_relative(view_relative)
        path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
        parts = path.split("/")
        filename = parts.pop
        return nil unless filename&.start_with?("_")

        parts.push(filename.sub(/\A_/, ""))
        parts.join("/")
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

        rbs = controller_rbs(controller_file, controller_class)

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

        # ActionViewContext (generated by rails_custom) bundles ActionView::Helpers,
        # _RbsRailsPathHelpers, ApplicationHelper, Kaminari::Helpers::HelperMethods,
        # and ApplicationController helper_methods.
        helpers << "ActionViewContext"

        helpers
      end

      # Collect helper_method declarations from controllers.
      # Returns a hash { method_name => type_signature }.
      def collect_helper_methods(view_info)
        methods = {}

        # ApplicationController helper_methods are now in the generated ApplicationHelper
        # (rails_custom generator). Only check the specific controller here.
        if view_info
          app_ctrl = File.join(@app_dir, "app/controllers/application_controller.rb")
          ctrl_file = find_controller_file(view_info[:controller_name])
          if ctrl_file && ctrl_file != app_ctrl
            methods.merge!(extract_helper_method_signatures(ctrl_file, view_info[:controller_class]))
          end
        end

        methods
      end

      # Parse a controller file for `helper_method` declarations and
      # extract the method signatures from its generated RBS.
      def extract_helper_method_signatures(controller_file, controller_class)
        source = File.read(controller_file)
        tree = Prism.parse(source).value

        # Collect helper_method names
        names = Set.new
        each_call(tree, :helper_method) do |call|
          call.arguments&.arguments&.each do |arg|
            names << arg.value if arg.is_a?(Prism::SymbolNode)
          end
        end
        return {} if names.empty?

        # Get method signatures from controller RBS
        rbs = controller_rbs(controller_file, controller_class)
        return {} unless rbs

        signatures = {}
        rbs.each_line do |line|
          stripped = line.strip
          if (m = stripped.match(/\Adef (\w+[?!]?): (.+)\z/))
            signatures[m[1]] = m[2] if names.include?(m[1])
          end
        end
        signatures
      end

      # Generate controller RBS (cached, shared with controller_ivar_types).
      def controller_rbs(controller_file, controller_class)
        @controller_rbs_cache ||= {}
        return @controller_rbs_cache[controller_class] if @controller_rbs_cache.key?(controller_class)

        @controller_rbs_cache[controller_class] = RbsInfer::Analyzer.new(
          target_class: controller_class,
          target_file: controller_file,
          source_files: @source_files
        ).generate_rbs
      end

      # ── Partial locals inference (Fase 2) ─────────────────────────

      # Scan all ERB files and controller files for `render partial:` calls
      # and collect locals with their inferred types.
      def collect_partial_locals(erb_files)
        locals_map = Hash.new { |h, k| h[k] = {} }

        # Scan ERB files for render calls (convert ERB → Ruby, then parse with Prism)
        erb_files.each do |erb_path|
          erb_source = File.read(erb_path)
          ruby_code = erb_to_ruby(erb_source)
          context_ivars = context_ivars_for_erb(erb_path)
          caller_dir = caller_view_dir_from_erb(erb_path)

          tree = Prism.parse(ruby_code).value
          local_var_types = build_local_var_types(tree, context_ivars)
          collect_render_locals_from_tree(tree, context_ivars, locals_map, caller_dir: caller_dir, local_var_types: local_var_types)
        end

        # Scan controller files for render calls
        Dir[File.join(@app_dir, "app/controllers/**/*.rb")].each do |ctrl_path|
          source = File.read(ctrl_path)
          tree = Prism.parse(source).value
          controller_class = extract_controller_class_from_path(ctrl_path)
          all_ivars = controller_class ? (controller_ivar_types(ctrl_path, controller_class) rescue {}) : {}
          caller_dir = caller_view_dir_from_controller(ctrl_path)

          collect_render_locals_from_tree(tree, all_ivars, locals_map, caller_dir: caller_dir)
        end

        locals_map
      end

      def erb_to_ruby(erb_source)
        require "herb"
        Herb.extract_ruby(erb_source, comments: true)
      end

      def extract_controller_class_from_path(ctrl_path)
        relative = ctrl_path.sub("#{@app_dir}/app/controllers/", "").sub(/\.rb\z/, "")
        relative.split("/").map { |s| s.split(/[_-]/).map(&:capitalize).join }.join("::")
      end

      # Get context ivars for an ERB file (from its controller action).
      def context_ivars_for_erb(erb_path)
        relative = erb_path.sub("#{@app_dir}/", "")
        view_relative = relative.sub(%r{\Aapp/views/}, "")
        view_info = parse_view_path(view_relative)
        return {} unless view_info

        controller_file = find_controller_file(view_info[:controller_name])
        return {} unless controller_file

        extract_action_ivars(controller_file, view_info[:controller_class], view_info[:action])
      end

      # Extract the view directory for an ERB caller.
      # "app/views/posts/edit.html.erb" → "posts"
      def caller_view_dir_from_erb(erb_path)
        relative = erb_path.sub("#{@app_dir}/", "").sub(%r{\Aapp/views/}, "")
        parts = relative.split("/")
        parts.pop # remove filename
        parts.empty? ? nil : parts.join("/")
      end

      # Extract the view directory for a controller caller.
      # "app/controllers/posts_controller.rb" → "posts"
      # "app/controllers/admin/posts_controller.rb" → "admin/posts"
      def caller_view_dir_from_controller(ctrl_path)
        relative = ctrl_path.sub("#{@app_dir}/app/controllers/", "").sub(/_controller\.rb\z/, "")
        relative.empty? ? nil : relative
      end

      # Resolve a short partial name to a full path using the caller's directory.
      # "form" with caller_dir "posts" → "posts/form"
      # "posts/form" (already qualified) → "posts/form"
      def resolve_partial_name(partial_name, caller_dir)
        return partial_name if partial_name.include?("/") || caller_dir.nil?

        "#{caller_dir}/#{partial_name}"
      end

      # Build a map of local variable names to their inferred types
      # by analyzing iterator blocks like `@comments.each do |comment|`.
      def build_local_var_types(tree, context_ivars)
        local_types = {}
        collect_iterator_var_types(tree, context_ivars, local_types)
        local_types
      end

      # Recursively collect block variable types from iterator patterns.
      # Handles: @ivar.each { |x| ... }, @ivar.map { |x| ... }, etc.
      def collect_iterator_var_types(node, context_ivars, local_types)
        if node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)
          block = node.block
          params = block.parameters&.parameters

          if params && node.receiver.is_a?(Prism::InstanceVariableReadNode)
            ivar_name = node.receiver.name.to_s.sub(/\A@/, "")
            collection_type = context_ivars[ivar_name]

            if collection_type
              element_type = element_type_from_collection(collection_type)
              if element_type && params.respond_to?(:requireds)
                first_param = params.requireds.first
                if first_param.respond_to?(:name)
                  local_types[first_param.name.to_s] = element_type
                end
              end
            end
          end
        end

        node.compact_child_nodes.each { |child| collect_iterator_var_types(child, context_ivars, local_types) }
      end

      # Extract element type from a collection type via RBS definitions.
      # Looks up the `each` method's block parameter type — works for any
      # collection class with `each` defined in RBS.
      def element_type_from_collection(type)
        rbs_definition_resolver.resolve_each_element_type(type)
      end

      def rbs_definition_resolver
        @rbs_definition_resolver ||= RbsDefinitionResolver.new
      end

      # Traverse a Prism AST collecting render calls with locals.
      def collect_render_locals_from_tree(tree, context_ivars, locals_map, caller_dir: nil, local_var_types: {})
        each_call(tree, :render) do |call|
          args = call.arguments&.arguments
          next unless args

          partial_name = nil
          locals_hash = nil

          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              next unless assoc.key.is_a?(Prism::SymbolNode)

              case assoc.key.value
              when "partial"
                partial_name = extract_string_value(assoc.value)
              when "locals"
                locals_hash = assoc.value if assoc.value.is_a?(Prism::HashNode)
              end
            end
          end

          partial_name = resolve_partial_name(partial_name, caller_dir) if partial_name
          next unless partial_name && locals_hash

          locals_hash.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::SymbolNode)

            local_name = element.key.value
            local_type = infer_local_value_type(element.value, context_ivars, local_var_types: local_var_types)
            next unless local_type

            existing = locals_map[partial_name][local_name]
            locals_map[partial_name][local_name] = if existing && existing != local_type
                                                     merge_types(existing, local_type)
                                                   else
                                                     local_type
                                                   end
          end
        end
      end

      def extract_string_value(node)
        case node
        when Prism::StringNode then node.content
        end
      end

      # Infer the type of a value passed as a local to a partial.
      def infer_local_value_type(node, context_ivars, local_var_types: {})
        case node
        when Prism::LocalVariableReadNode
          local_var_types[node.name.to_s]
        when Prism::InstanceVariableReadNode
          ivar_name = node.name.to_s.sub(/\A@/, "")
          context_ivars[ivar_name]
        when Prism::StringNode, Prism::InterpolatedStringNode then "String"
        when Prism::IntegerNode then "Integer"
        when Prism::FloatNode then "Float"
        when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
        when Prism::TrueNode then "bool"
        when Prism::FalseNode then "bool"
        when Prism::NilNode then "nil"
        when Prism::ArrayNode then "Array[untyped]"
        when Prism::HashNode then "Hash[untyped, untyped]"
        when Prism::CallNode
          if node.name == :new && node.receiver
            RbsInfer::Analyzer.extract_constant_path(node.receiver)
          end
        end
      end

      def merge_types(type_a, type_b)
        types = [type_a, type_b].flat_map { |t| t.split(" | ") }.uniq
        types.join(" | ")
      end

      # ── RBS output ────────────────────────────────────────────────

      def build_rbs(class_name, ivar_types, local_types, helpers, helper_methods = {})
        lines = ["# Generated by rbs_infer (erb_convention)", ""]
        lines << "class #{class_name}"

        ivar_types.each do |name, type|
          lines << "  @#{name}: #{type}"
        end

        local_types.each do |name, type|
          lines << "  attr_reader #{name}: #{type}"
        end

        helper_methods.each do |name, signature|
          lines << "  def #{name}: #{signature}"
        end

        lines << "  def params: () -> ActionController::Parameters"

        helpers.each do |helper|
          lines << "  include #{helper}"
        end

        lines << "end"
        lines.join("\n") + "\n"
      end
    end
  end
end
