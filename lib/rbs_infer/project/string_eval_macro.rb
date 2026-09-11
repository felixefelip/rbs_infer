# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # A method that defines methods by `class_eval`ing a STRING it interpolates
  # its own parameters into — and what one of its call sites therefore defines.
  #
  #   def has_rich_text(name, store_if_blank: true)
  #     class_eval <<-CODE
  #       def #{name}
  #         rich_text_#{name} || build_rich_text_#{name}
  #       end
  #     CODE
  #   end
  #
  # `ClassEvalExpander` desugars `X.class_eval do … end` and
  # `StoredBlockReplayExpander` moves a stored BLOCK to the receiver that
  # replays it. Both read Ruby, because a block IS Ruby. This is the third
  # spelling and the one every static reader stops at: the body is a string, so
  # there is no AST to move until the interpolation has a value — and the value
  # comes from a call site, in another file, one per caller.
  #
  # Which is what makes it expandable rather than out of scope. `#{name}` is not
  # dynamic in the `eval`/`method_missing` sense: `has_rich_text :content` says
  # what it is, in the source, and a human reading those two files together
  # writes `def content` without running anything. The rule in the README says
  # the tooling has to.
  #
  # Deliberately conservative — every uncertainty declines the whole macro
  # rather than emitting part of it:
  #
  #   * an interpolation that is not a plain read of one of the method's own
  #     parameters (`#{name.to_s.camelize}`, `#{SOME_CONST}`) has no value here;
  #   * a parameter that binds to anything but a symbol/string literal at the
  #     call site has no text to interpolate;
  #   * a `class_eval` under a condition this cannot decide from literals is not
  #     known to run.
  #
  # Declining the MACRO, not the chunk: emitting a reader whose writer was
  # declined is not "less", it is a class that silently has no `x=`.
  module StringEvalMacro
    EVAL_METHODS = %i[class_eval module_eval].freeze

    # `parameters` is the def's own parameter list, needed to bind a call site's
    # arguments; `chunks` are the `class_eval` strings with the conditions each
    # sits under.
    Macro = Struct.new(:name, :parameters, :chunks, keyword_init: true)

    # One `class_eval "…"`, as the parts it is built from plus the conditions
    # guarding it. Nothing is evaluated at definition time, because which branch
    # runs depends on the call site this does not have yet.
    Chunk = Struct.new(:parts, :guards, keyword_init: true)

    module_function

    # Cheap enough to run over a file's text before parsing it, and the only
    # thing that decides whether a project pays for this pass at all.
    def possible?(source)
      EVAL_METHODS.any? { |name| source.include?(name.to_s) }
    end

    # Every macro a parsed file declares, by method name. A file can declare
    # several; a name declared twice ANYWHERE is dropped by the index, not here.
    def macros_in(root)
      find_defs(root).filter_map { |node| macro_for(node) }
    end

    def macro_for(node)
      chunks = []
      collect(node.body, [], chunks)
      return nil if chunks.empty?
      # A string this cannot rebuild fails the whole macro: the parts it could
      # rebuild are the other methods of the same declaration.
      return nil if chunks.any? { |chunk| chunk.parts.nil? }

      Macro.new(name: node.name, parameters: node.parameters, chunks: chunks)
    end

    # Walks a method body collecting each `class_eval`'s string argument with
    # the conditions it sits under, so a body written in one branch is only
    # rendered for the call sites that take that branch.
    #
    # The guard is kept as the predicate NODE and the branch's polarity;
    # nothing is decided here, because the values are the call site's.
    def collect(node, guards, acc)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::IfNode
        collect(node.statements, guards + [[node.predicate, true]], acc)
        collect(node.subsequent, guards + [[node.predicate, false]], acc)
      when Prism::UnlessNode
        collect(node.statements, guards + [[node.predicate, false]], acc)
        collect(node.else_clause, guards + [[node.predicate, true]], acc)
      when Prism::ElseNode
        collect(node.statements, guards, acc)
      when Prism::CallNode
        if EVAL_METHODS.include?(node.name) && node.receiver.nil? && node.block.nil? &&
           (arg = node.arguments&.arguments&.first)
          acc << Chunk.new(parts: parts_of(arg), guards: guards)
          return
        end

        node.compact_child_nodes.each { |child| collect(child, guards, acc) }
      else
        node.compact_child_nodes.each { |child| collect(child, guards, acc) }
      end
    end

    # `[[:str, "def "], [:param, :name], …]`, or nil for a string this cannot
    # rebuild. A plain (uninterpolated) string is a macro too — it defines the
    # same methods for every caller — and costs nothing to support.
    def parts_of(node)
      case node
      when Prism::StringNode
        [[:str, node.unescaped]]
      when Prism::InterpolatedStringNode
        parts = node.parts.map { |part| part_of(part) }
        parts.all? ? parts : nil
      end
    end

    def part_of(part)
      case part
      when Prism::StringNode
        [:str, part.unescaped]
      when Prism::EmbeddedStatementsNode
        body = part.statements&.body
        return nil unless body&.size == 1

        name = parameter_read(body.first) or return nil
        [:param, name]
      end
    end

    # A bare read of a name, which is how a method's own parameter appears
    # inside its body — as a local variable, or (where Prism cannot tell) as a
    # receiverless call taking nothing. Anything with a receiver, an argument or
    # a block is an expression, and expressions are declined.
    def parameter_read(node)
      case node
      when Prism::LocalVariableReadNode
        node.name
      when Prism::CallNode
        node.name if node.receiver.nil? && node.arguments.nil? && node.block.nil?
      end
    end

    def find_defs(root)
      RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::DefNode) }
    end
  end
end
