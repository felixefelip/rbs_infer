# frozen_string_literal: true

require "prism"
require_relative "string_eval_macro"
require_relative "string_eval_macro_index"

module RbsInfer::Project
  # Rewrites a class body's macro calls into the methods they define, by
  # rendering the macro's `class_eval` string with that call site's arguments.
  #
  #   class Article < ApplicationRecord
  #     has_rich_text :content
  #   end
  #
  # becomes, with the definition in `StringEvalMacro`'s example:
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
  # Core rather than an extension, and by the litmus in
  # docs/engineering/keep-core-framework-agnostic.md: `class_eval` with an
  # interpolated string is plain Ruby, and nothing here names a gem. `attr_*`
  # written by hand, a `define_*` macro in an app's own concern, and Rails'
  # `has_rich_text` are one shape; the ActionText generator's only job is to put
  # the gem's source where this can read it.
  module StringEvalMacroExpander
    module_function

    # Returns the expanded source, or nil when nothing was rewritten.
    def expand(source, macros:)
      return nil unless macros.any?

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      reopens = []
      walk(parsed.value, [], macros, reopens)
      return nil if reopens.empty?

      "#{source.chomp}\n\n#{reopens.join("\n")}"
    end

    # The class/module bodies, with their lexical nesting, so a call written in
    # `class Entry` inside `module Blog` reopens `Blog::Entry` — the class that
    # made the call, rather than a new top-level one.
    def walk(node, namespace, macros, reopens)
      return unless node.is_a?(Prism::Node)

      unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        node.compact_child_nodes.each { |child| walk(child, namespace, macros, reopens) }
        return
      end

      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)&.delete_prefix("::")
      # A constant path this cannot name (`class self::Thing`) stops the walk:
      # anything below it would be attributed to the wrong owner.
      return unless name

      qualified = (namespace + [name]).join("::")
      bodies = expansions_for(node, macros)
      reopens << reopen(qualified, bodies.join("\n"), node) unless bodies.empty?

      walk(node.body, namespace + [name], macros, reopens)
    end

    # A call in the body, and only in the body: a macro call written inside a
    # `def` runs when that method runs, on whatever `self` is then, which this
    # cannot name. Nested class bodies are reached by the walk, under their own
    # name.
    def expansions_for(node, macros)
      statements(node.body).filter_map do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.block.nil?

        macro = macros[stmt.name] or next

        render(macro, stmt)
      end
    end

    # The macro's defs for this call site, or nil when any part of it cannot be
    # decided — see the conservatism note on `StringEvalMacro`.
    def render(macro, call)
      bindings = bind(macro.parameters, call) or return nil

      chunks = macro.chunks.select do |chunk|
        held = guards_hold?(chunk.guards, bindings)
        return nil if held == :undecidable

        held
      end
      return nil if chunks.empty?

      rendered = chunks.filter_map { |chunk| render_parts(chunk.parts, bindings) }
      return nil unless rendered.size == chunks.size

      rendered.join("\n")
    end

    # `{ name: <Prism node> }` for the macro's parameters, taking the call
    # site's arguments where it passes them and the definition's defaults where
    # it does not. nil when the call cannot be matched to the signature —
    # more positional arguments than parameters, a splat, a double-splat.
    def bind(parameters, call)
      arguments = (call.arguments&.arguments || []).dup
      return nil if arguments.any? { |arg| arg.is_a?(Prism::SplatNode) }

      keywords = arguments.last.is_a?(Prism::KeywordHashNode) ? arguments.pop : nil
      return nil if parameters.nil? && !arguments.empty?

      bindings = {}
      bind_positional(parameters, arguments, bindings) or return nil
      bind_keywords(parameters, keywords, bindings) or return nil
      bindings
    end

    def bind_positional(parameters, arguments, bindings)
      slots = (parameters&.requireds || []) + (parameters&.optionals || [])
      return nil if arguments.size > slots.size

      slots.each_with_index do |slot, index|
        next unless slot.respond_to?(:name)

        bindings[slot.name] = arguments[index] || (slot.respond_to?(:value) ? slot.value : nil)
      end
      bindings
    end

    def bind_keywords(parameters, keywords, bindings)
      passed = {}
      (keywords&.elements || []).each do |element|
        # `**opts` in the call, or a non-literal key: which keyword it sets is
        # not knowable here.
        return nil unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

        passed[element.key.unescaped.to_sym] = element.value
      end

      (parameters&.keywords || []).each do |keyword|
        bindings[keyword.name] = passed.fetch(keyword.name) do
          keyword.respond_to?(:value) ? keyword.value : nil
        end
      end
      bindings
    end

    # true / false / :undecidable. A guard holds only when every condition
    # resolves to a literal that says so; `:undecidable` declines the macro
    # rather than picking a branch.
    def guards_hold?(guards, bindings)
      guards.each do |predicate, polarity|
        value = truthy?(bound(predicate, bindings))
        return :undecidable if value == :undecidable
        return false unless value == polarity
      end

      true
    end

    # What a predicate that is nothing but a parameter read is bound to. A
    # comparison, a negation or a call is an expression, and expressions are not
    # decided here.
    def bound(predicate, bindings)
      name = StringEvalMacro.parameter_read(predicate) or return nil

      bindings[name]
    end

    def truthy?(node)
      case node
      when Prism::TrueNode then true
      when Prism::FalseNode, Prism::NilNode, nil then false
      else :undecidable
      end
    end

    # The chunk as source, or nil when a parameter it interpolates has no text
    # at this call site.
    def render_parts(parts, bindings)
      rendered = parts.map do |kind, value|
        next value if kind == :str

        text_for(bindings[value]) or return nil
      end

      dedent(rendered.join)
    end

    # The text a value interpolates to. A symbol and a string interpolate the
    # same way Ruby does — `:content` and `"content"` both write `content` —
    # which is why a macro accepts either.
    def text_for(node)
      case node
      when Prism::SymbolNode then node.unescaped
      when Prism::StringNode then node.unescaped
      end
    end

    # The heredoc carries the gem's own indentation and the reopen supplies its
    # own. Stripped by the SMALLEST indentation any line has, so a body's
    # internal shape — an `if` inside a writer — survives the move.
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
