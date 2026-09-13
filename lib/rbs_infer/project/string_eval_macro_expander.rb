# frozen_string_literal: true

require "prism"
require_relative "string_eval_sidecar"

module RbsInfer::Project
  # Rewrites a class body's macro calls into the methods they define, from the
  # source the checker folded at each call site.
  #
  #   class Article < ApplicationRecord
  #     has_rich_text :content
  #   end
  #
  # becomes, for a `has_rich_text` that `class_eval`s an interpolated string:
  #
  #   class Article < ApplicationRecord
  #     has_rich_text :content
  #   end
  #
  #   class Article
  #     def content
  #       rich_text_content || build_rich_text_content
  #     end
  #   end
  #
  # APPENDED rather than substituted, unlike `ClassEvalExpander`: the call is
  # not the thing being desugared away. It stays a real call, because it is one
  # — it is evidence about the macro's own parameters, and the RBS the macro
  # gets should keep reading it.
  #
  # Nothing here reads the macro. Which text a call site interpolates, which
  # branch of the macro it takes and what an omitted keyword defaults to are
  # value questions the type machinery already answers — see
  # `StringEvalSidecar` — so this places what it is handed and decides only
  # WHERE, which is the one thing the sidecar cannot say: the class whose body
  # holds the call.
  #
  # Core rather than an extension, and by the litmus in
  # docs/engineering/keep-core-framework-agnostic.md: `class_eval` with an
  # interpolated string is plain Ruby, and nothing here names a gem. `attr_*`
  # written by hand, a `define_*` macro in an app's own concern, and Rails'
  # `has_rich_text` are one shape; the ActionText generator's only job is to put
  # the gem's source where the checker can read it.
  module StringEvalMacroExpander
    module_function

    # The reopens this file's macro calls define, or nil when it has none.
    #
    # `source` is the file AS THE CHECKER READ IT — the source on disk, not an
    # expander's rewrite of it. The sidecar points at a line and a column, and
    # an expansion that ran first may have moved both.
    def reopens(source, path:, sidecar:)
      return nil unless sidecar.any?

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      reopens = []
      walk(parsed.value, [], path, sidecar, reopens)
      return nil if reopens.empty?

      reopens.join("\n")
    end

    # The class/module bodies, with their lexical nesting, so a call written in
    # `class Entry` inside `module Blog` reopens `Blog::Entry` — the class that
    # made the call, rather than a new top-level one.
    def walk(node, namespace, path, sidecar, reopens)
      return unless node.is_a?(Prism::Node)

      unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        node.compact_child_nodes.each { |child| walk(child, namespace, path, sidecar, reopens) }
        return
      end

      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)&.delete_prefix("::")
      # A constant path this cannot name (`class self::Thing`) stops the walk:
      # anything below it would be attributed to the wrong owner.
      return unless name

      qualified = (namespace + [name]).join("::")
      bodies = expansions_for(node, path, sidecar)
      reopens << reopen(qualified, bodies.join("\n"), node) unless bodies.empty?

      walk(node.body, namespace + [name], path, sidecar, reopens)
    end

    # A call in the body, and only in the body: a macro call written inside a
    # `def` runs when that method runs, on whatever `self` is then, which this
    # cannot name. Nested class bodies are reached by the walk, under their own
    # name.
    def expansions_for(node, path, sidecar)
      statements(node.body).filter_map do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.block.nil?

        sources = sidecar.sources_for(
          path: path,
          line: stmt.location.start_line,
          column: stmt.location.start_column
        )
        next unless sources

        sources.map { |source| dedent(source) }.join("\n")
      end
    end

    # The heredoc a macro is written with carries the gem's own indentation and
    # the reopen supplies its own. Stripped by the SMALLEST indentation any line
    # has, so a body's internal shape — an `if` inside a writer — survives.
    def dedent(source)
      lines = source.lines
      margin = lines.reject { |line| line.strip.empty? }
                    .map { |line| line[/\A */].length }.min || 0

      # A blank line keeps the heredoc's indentation as trailing whitespace,
      # which the margin does not describe — it is emitted bare.
      lines.map { |line| line.strip.empty? ? "\n" : line[margin..] }.join
    end

    # `class` for a class and `module` for a module, so the reopen matches what
    # it reopens — a mismatch is a TypeError at load in Ruby, and a wrong owner
    # here.
    def reopen(name, body, node)
      keyword = node.is_a?(Prism::ClassNode) ? "class" : "module"
      indented = body.rstrip.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join

      "#{keyword} #{name}\n#{indented}\nend\n"
    end

    def statements(body)
      body.is_a?(Prism::StatementsNode) ? body.body : []
    end
  end
end
