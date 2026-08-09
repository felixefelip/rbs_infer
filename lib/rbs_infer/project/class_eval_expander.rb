# frozen_string_literal: true

require "prism"
require_relative "source_expanders"

module RbsInfer::Project
  # Desugars `X.class_eval do ... end` / `X.module_eval do ... end` with a CONSTANT
  # receiver into a plain `class X ... end` reopening, so the generic multi-target
  # pipeline attributes the body to `X` on its own.
  #
  #   EvalReopen.class_eval do
  #     def by_class_eval; 2; end
  #   end
  #   # becomes:
  #   class EvalReopen
  #     def by_class_eval; 2; end
  #   end
  #
  # It is the same operation: the block's default definee is the receiver, so a `def`
  # inside defines the receiver's instance method. Without the rewrite the body was
  # attributed to nothing — every method defined in the block simply vanished from the
  # emitted RBS.
  #
  # Unlike the other expanders this one is CORE, not an extension, and is registered
  # unconditionally. `class_eval` is plain Ruby: the litmus in
  # docs/engineering/keep-core-framework-agnostic.md ("would this make sense for a gem
  # that doesn't exist?") says yes, so no `extensions/` home is right. It uses the
  # `SourceExpanders` seam anyway because the seam is the correct mechanism — the
  # desugared body then flows through the same owner/visibility/return-type machinery
  # every ordinary class body uses, instead of teaching TargetDiscovery, LexicalScope,
  # DefCollector and ClassMemberCollector the call shape one at a time.
  #
  # The matching checker-side change is felixefelip/steep#135, which reads the same
  # call shape as an implicit `@implements` so `super` inside the block resolves
  # against the receiver's ancestors.
  module ClassEvalExpander
    # `instance_eval` is deliberately absent: its default definee is the receiver's
    # SINGLETON class, so rewriting it to `class X` would attribute the def to the
    # instance side — the wrong half. steep#135 declines it for the same reason, which
    # keeps the two sides agreeing.
    REOPENING_METHODS = %w[class_eval module_eval].freeze

    # A block nested inside another match is rewritten on a later pass, once the outer
    # one has become an ordinary class body. Replacing both at once would corrupt the
    # source: the offsets of the inner match are inside the outer's replaced range.
    MAX_PASSES = 10

    module_function

    # Returns the expanded source, or nil when there is nothing to rewrite.
    def expand(source)
      result = nil

      MAX_PASSES.times do
        expanded = expand_once(result || source)
        break unless expanded

        result = expanded
      end

      result
    end

    def expand_once(source)
      return nil unless REOPENING_METHODS.any? { |name| source.include?(name) }

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      calls = RbsInfer::Analyzer.find_all_nodes(parsed.value) { |node| reopening_block?(node) }
      replacements = outermost(calls).map { |call| replacement_for(source, call) }.compact
      return nil if replacements.empty?

      apply_replacements(source, replacements)
    end

    # `X.class_eval do ... end` with no arguments. The STRING form
    # (`class_eval "def x; end"`) is excluded by requiring a block and no arguments:
    # its body is not source this can read, and is the genuinely undecidable case the
    # README reserves for `eval`. A non-constant receiver (`obj.class_eval`,
    # `self.class_eval`) reopens whatever class the value happens to be, which the
    # shape does not say.
    def reopening_block?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless REOPENING_METHODS.include?(node.name.to_s)
      return false unless node.block.is_a?(Prism::BlockNode)
      return false if node.arguments

      constant_receiver?(node.receiver)
    end

    def constant_receiver?(node)
      node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    end

    # Drops any match whose byte range sits inside another's, so one pass only ever
    # rewrites non-overlapping ranges.
    def outermost(calls)
      calls.reject do |call|
        calls.any? do |other|
          next false if other.equal?(call)

          other.location.start_offset <= call.location.start_offset &&
            call.location.end_offset <= other.location.end_offset
        end
      end
    end

    def replacement_for(source, call)
      name = RbsInfer::Analyzer.extract_constant_path(call.receiver)
      return nil unless name && !name.empty?

      body = call.block.body
      body_source = body ? slice(source, body) : ""

      {
        start: call.location.start_offset,
        end: call.location.end_offset,
        text: "class #{name}\n#{body_source}\nend",
      }
    end

    def slice(source, node)
      source.byteslice(node.location.start_offset, node.location.end_offset - node.location.start_offset)
    end

    # Back to front so earlier byte offsets stay valid (mirrors the other expanders).
    def apply_replacements(source, replacements)
      out = source.dup
      replacements.sort_by { |r| -r[:start] }.each do |r|
        out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
      end
      out
    end
  end

  SourceExpanders.register(ClassEvalExpander)
end
