# frozen_string_literal: true

require "prism"
require_relative "../../../rbs_infer"

module RbsInfer
  module Extensions
    module Rails
      class ConcernAnnotationGenerator
        def initialize(app_dir:, source_files: nil)
          @app_dir = app_dir
          @source_files = source_files || Dir[File.join(app_dir, "app/models/**/*.rb")]
        end

        def generate_all
          @source_files.each { |file| annotate_file(file) }
        end

        private

        def annotate_file(file)
          return unless File.exist?(file)

          source = File.read(file)
          result = Prism.parse(source)
          lines = source.lines
          insertions = []

          each_module(result.value) do |mod_node|
            module_name = RbsInfer::Analyzer.extract_constant_path(mod_node.constant_path)
            next unless module_name

            # Idempotency: skip if this module is already annotated
            next if source.match?(/@type instance:.*#{Regexp.escape(module_name)}/)

            is_concern = concern?(mod_node)
            including_class = resolve_including_class(module_name)
            next unless including_class

            indent = detect_indent(mod_node, lines)
            insert_at, new_lines = build_insertion(mod_node, is_concern, module_name, including_class, indent)
            insertions << { at: insert_at, lines: new_lines }
          end

          return if insertions.empty?

          # Apply from bottom to top so earlier indices stay valid
          insertions.sort_by { |i| -i[:at] }.each do |ins|
            lines.insert(ins[:at], *ins[:lines])
          end

          File.write(file, lines.join)
        end

        def each_module(node, &block)
          yield node if node.is_a?(Prism::ModuleNode)
          node.compact_child_nodes.each { |child| each_module(child, &block) }
        end

        def concern?(mod_node)
          body = mod_node.body
          return false unless body

          stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          stmts.any? do |stmt|
            next unless stmt.is_a?(Prism::CallNode) && stmt.name == :extend
            stmt.arguments&.arguments&.any? do |arg|
              RbsInfer::Analyzer.extract_constant_path(arg) == "ActiveSupport::Concern"
            end
          end
        end

        def find_extend_node(mod_node)
          body = mod_node.body
          return nil unless body

          stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          stmts.find do |stmt|
            next unless stmt.is_a?(Prism::CallNode) && stmt.name == :extend
            stmt.arguments&.arguments&.any? do |arg|
              RbsInfer::Analyzer.extract_constant_path(arg) == "ActiveSupport::Concern"
            end
          end
        end

        # Strategy A: infer including class from the module namespace (Post::Taggable → Post).
        # Strategy B: scan source files for `include ModuleName` as fallback.
        def resolve_including_class(module_name)
          parts = module_name.split("::")
          return parts[0..-2].join("::") if parts.size > 1

          @source_files.each do |file|
            next unless File.exist?(file)
            source = File.read(file)
            next unless source.include?(module_name)

            klass = find_class_including(Prism.parse(source).value, module_name)
            return klass if klass
          end

          nil
        end

        def find_class_including(tree, module_name)
          result = nil
          each_class(tree) do |class_node|
            each_call(class_node, :include) do |call|
              call.arguments&.arguments&.each do |arg|
                if RbsInfer::Analyzer.extract_constant_path(arg) == module_name
                  result = RbsInfer::Analyzer.extract_constant_path(class_node.constant_path)
                end
              end
            end
          end
          result
        end

        def each_class(node, &block)
          yield node if node.is_a?(Prism::ClassNode)
          node.compact_child_nodes.each { |child| each_class(child, &block) }
        end

        def each_call(node, method_name, &block)
          yield node if node.is_a?(Prism::CallNode) && node.name == method_name
          node.compact_child_nodes.each { |child| each_call(child, method_name, &block) }
        end

        # Infer indentation from the first statement in the module body.
        def detect_indent(mod_node, lines)
          body = mod_node.body
          return "  " unless body

          first_stmt = body.is_a?(Prism::StatementsNode) ? body.body.first : body
          return "  " unless first_stmt

          line = lines[first_stmt.location.start_line - 1]
          line&.match(/\A(\s+)/)&.[](1) || "  "
        end

        def build_insertion(mod_node, is_concern, module_name, including_class, indent)
          if is_concern
            extend_node = find_extend_node(mod_node)
            # end_line is 1-based; used directly as 0-based index of the line after `extend`
            insert_at = extend_node.location.end_line

            new_lines = [
              "\n",
              "#{indent}# @type self: singleton(#{including_class}) & singleton(#{module_name})\n",
              "#{indent}# @type instance: #{including_class} & #{module_name}\n"
            ]

            [insert_at, new_lines]
          else
            # start_line is 1-based; used directly as 0-based index of the line after `module`
            insert_at = mod_node.location.start_line

            new_lines = [
              "#{indent}# @type instance: #{including_class} & #{module_name}\n",
              "\n"
            ]

            [insert_at, new_lines]
          end
        end
      end
    end
  end
end
