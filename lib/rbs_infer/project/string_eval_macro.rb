# frozen_string_literal: true

require "prism"
require_relative "literal_fold"

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
  # Both halves of that — what `#{name}` interpolates to, and whether the `if`
  # around it runs — are the same question, and `LiteralFold` is the one
  # function that answers it. They were two readers once, with two ideas of
  # "I cannot tell", and the condition side spelled its unknown `false`: a
  # predicate it could not read did not decline, it selected the `else` branch
  # and emitted the methods written there.
  #
  # So uncertainty is one value, propagated by one folder, and it declines:
  #
  #   * an interpolation whose value the folder cannot reach
  #     (`#{name.to_s.camelize}`, `#{SOME_CONST}`) has no text here;
  #   * a parameter that binds to anything outside the folder's domain at the
  #     call site has none either;
  #   * a `class_eval` under a condition the folder cannot decide — including
  #     one written in a shape this walk does not read at all — is not known to
  #     run, and `UNREADABLE` is how the walk says so.
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

    # One condition a chunk sits under. With no `subject` the single node is a
    # predicate, tested for truthiness — an `if`, an `unless`, a subjectless
    # `case`. With one, the nodes are a `when`'s values and the test is whether
    # any equals the subject. `expected` is the answer that lets the chunk run.
    Guard = Struct.new(:subject, :nodes, :expected, keyword_init: true)

    # A condition this reader did not understand AT ALL — a block, a `while`, a
    # `rescue`, a call it cannot fold. Never true and never false: a chunk under
    # one is not known to run, so the macro declines.
    #
    # Collected rather than skipped, which is the whole reason it exists.
    # Skipping the subtree would drop that chunk silently and let the macro's
    # OTHER chunks render — a reader emitted without the writer that vanished.
    UNREADABLE = Guard.new(subject: nil, nodes: nil, expected: nil).freeze

    # Nodes that only hold other nodes. Passing through one neither decides nor
    # obscures whether what is inside runs, so the guards carry over unchanged.
    # Everything not listed is a barrier — the default is refusal.
    TRANSPARENT = [Prism::StatementsNode, Prism::ElseNode].freeze

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
    # The conditions are kept as NODES; nothing is decided here, because the
    # values are the call site's. What IS decided here is whether a condition
    # was read at all — anything this does not recognise contributes
    # `UNREADABLE`, and a chunk carrying one can never be selected.
    def collect(node, guards, acc)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::IfNode
        # The predicate is walked too, under a barrier: a `class_eval` hiding in
        # a condition must poison the macro, not disappear from it.
        collect(node.predicate, guards + [UNREADABLE], acc)
        collect(node.statements, guards + [truthy_guard(node.predicate, true)], acc)
        collect(node.subsequent, guards + [truthy_guard(node.predicate, false)], acc)
      when Prism::UnlessNode
        collect(node.predicate, guards + [UNREADABLE], acc)
        collect(node.statements, guards + [truthy_guard(node.predicate, false)], acc)
        collect(node.else_clause, guards + [truthy_guard(node.predicate, true)], acc)
      when Prism::CaseNode
        collect_case(node, guards, acc)
      when Prism::AndNode, Prism::OrNode
        # `writable && class_eval("…")` is a condition spelled without an `if`,
        # and the left side is what decides it. Read rather than refused,
        # because the folder reads the same shape when it appears as a value.
        collect(node.left, guards, acc)
        collect(node.right, guards + [truthy_guard(node.left, node.is_a?(Prism::AndNode))], acc)
      when Prism::BeginNode
        # `begin … rescue … end`: the body runs, everything else is a question
        # about what raised.
        collect(node.statements, guards, acc)
        node.compact_child_nodes.each do |child|
          collect(child, guards + [UNREADABLE], acc) unless child.equal?(node.statements)
        end
      when Prism::CallNode
        if eval_call?(node) && (argument = node.arguments&.arguments&.first)
          acc << Chunk.new(parts: parts_of(argument), guards: guards)
          return
        end

        descend(node, guards + [UNREADABLE], acc)
      else
        descend(node, transparent?(node) ? guards : guards + [UNREADABLE], acc)
      end
    end

    # `case x when :a … when :b … else … end`, as the chain of conditions it is:
    # a `when` runs when its own comparison holds AND no earlier one did. That
    # chain is the reason a `case` is read rather than refused — the alternative
    # was collecting every branch with no guard at all, which rendered them all.
    def collect_case(node, guards, acc)
      collect(node.predicate, guards + [UNREADABLE], acc)
      preceding = []

      node.conditions.each do |condition|
        unless condition.is_a?(Prism::WhenNode)
          collect(condition, guards + [UNREADABLE], acc)
          next
        end

        collect(condition.statements, guards + preceding + [case_guard(node.predicate, condition, true)], acc)
        preceding += [case_guard(node.predicate, condition, false)]
      end

      collect(node.else_clause, guards + preceding, acc)
    end

    # true / false / LiteralFold::UNKNOWN — whether a chunk under this guard
    # runs for the call site these bindings describe.
    def guard_holds?(guard, bindings)
      return LiteralFold::UNKNOWN if guard.nodes.nil?

      answer = guard.subject ? subject_matches?(guard, bindings) : any_truthy?(guard.nodes, bindings)
      return LiteralFold::UNKNOWN if LiteralFold.unknown?(answer)

      answer == guard.expected
    end

    def truthy_guard(predicate, expected)
      Guard.new(subject: nil, nodes: [predicate], expected: expected)
    end

    def case_guard(subject, when_node, expected)
      Guard.new(subject: subject, nodes: when_node.conditions, expected: expected)
    end

    def any_truthy?(nodes, bindings)
      nodes.reduce(false) do |held, node|
        value = LiteralFold.truthy(LiteralFold.fold(node, bindings))
        return LiteralFold::UNKNOWN if LiteralFold.unknown?(value)

        held || value
      end
    end

    # `when` dispatches on `===`, which for every value this folds — strings,
    # symbols, true/false/nil — is `==`. A `when` naming a class or a range
    # folds to UNKNOWN and never reaches the comparison.
    def subject_matches?(guard, bindings)
      subject = LiteralFold.fold(guard.subject, bindings)
      return LiteralFold::UNKNOWN if LiteralFold.unknown?(subject)

      guard.nodes.reduce(false) do |held, node|
        value = LiteralFold.fold(node, bindings)
        return LiteralFold::UNKNOWN if LiteralFold.unknown?(value)

        held || value == subject
      end
    end

    def eval_call?(node)
      EVAL_METHODS.include?(node.name) && node.receiver.nil? && node.block.nil?
    end

    def transparent?(node)
      TRANSPARENT.any? { |type| node.is_a?(type) }
    end

    def descend(node, guards, acc)
      node.compact_child_nodes.each { |child| collect(child, guards, acc) }
    end

    # `[[:str, "def "], [:node, <Prism node>], …]`, or nil for a string this
    # cannot rebuild. A plain (uninterpolated) string is a macro too — it
    # defines the same methods for every caller — and costs nothing to support.
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

        # The NODE, not a parameter name. What it evaluates to is a question
        # about a call site, and `LiteralFold` is what answers it there — the
        # same function, with the same unknown, that answers the conditions.
        [:node, body.first]
      end
    end

    def find_defs(root)
      RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::DefNode) }
    end
  end
end
