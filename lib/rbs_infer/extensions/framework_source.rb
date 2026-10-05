# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    # Slicing a framework's own source out of the installed gem — what every
    # transcriber does before it adds anything of its own.
    #
    # A transcription is the gem's code, not a paraphrase of it (see
    # `Rails::Controllers::FrameworkSourceTranscriber`), so the one thing all of
    # them share is FINDING that code: from a method the runtime can name, to
    # the node in the file it was read from, to its source at column zero.
    # Located by POSITION rather than by name throughout, so a file that defines
    # a name twice cannot be confused.
    module FrameworkSource
      module_function

      # The `def` of `method`, read from the file its `source_location` names,
      # or nil when there is no such file — a method defined in C, or by eval.
      def def_node(method)
        file, line = method.source_location
        return nil unless file && line && File.file?(file)

        def_node_at(file, line)
      end

      # The `def` whose own line is `line`.
      def def_node_at(file, line)
        root = parse(file) or return nil

        RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::DefNode) }
                          .find { |n| n.location.start_line == line }
      end

      # The innermost `module`/`class` named `name` (its last segment) that
      # encloses `line` in `file` — the body a method is written in, when the
      # transcription needs more of it than the method: its constants, its
      # `class << self`.
      def enclosing_namespace(file, line, name)
        root = parse(file) or return nil

        RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::ModuleNode) || n.is_a?(Prism::ClassNode) }
                          .select { |n| n.name.to_s == name && n.location.start_line <= line && line <= n.location.end_line }
                          .max_by { |n| n.location.start_line }
      end

      def parse(file)
        result = Prism.parse_file(file)
        result.success? ? result.value : nil
      end

      # `node`'s own source, moved to column zero.
      def source(node)
        dedent(node.slice, node.location.start_column)
      end

      # `node.slice` starts AT the node's first keyword, so the first line
      # carries no indentation while the rest keep the file's. The margin to
      # strip is therefore the node's own column, not the minimum across lines
      # — which is zero, and leaves every body at the gem's absolute
      # indentation.
      def dedent(source, margin)
        first, *rest = source.lines
        ([first] + rest.map { |line| line.strip.empty? ? line : line.sub(/\A {0,#{margin}}/, "") }).join
      end

      # `source` indented by `depth` levels, blank lines left blank.
      def indent(source, depth)
        source.lines.map { |line| line.strip.empty? ? "\n" : "#{'  ' * depth}#{line}" }.join
      end
    end
  end
end
