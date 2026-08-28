# frozen_string_literal: true

require "prism"
require_relative "source_expanders"
require_relative "reopening_call"
require_relative "block_reopen"

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
    module_function

    # Returns the expanded source, or nil when there is nothing to rewrite.
    #
    # A block nested inside another match is rewritten on a later pass, once the outer
    # one has become an ordinary class body. Replacing both at once would corrupt the
    # source: the offsets of the inner match are inside the outer's replaced range.
    # Only NESTING costs a pass — any number of non-overlapping calls are rewritten
    # together (measured: fifteen siblings, one pass).
    #
    # The bound is what the source writes, not a constant. A fixed ten looked like a
    # guard and was a depth limit: measured, eleven nested reopenings came out still
    # holding a `class_eval`, which is both a wrong answer and an output this expander
    # wants to rewrite again — the non-idempotent result `SourceExpanders` asks an
    # expander not to produce (felixefelip/rbs_infer#269 fixed the same shape in
    # `ConstantDeclarationExpander`). Bounding by the count still terminates if some
    # future rewrite stops reducing, which is what a ceiling is really for.
    def expand(source)
      result = nil

      ReopeningCall.count(source).times do
        expanded = expand_once(result || source)
        break unless expanded

        result = expanded
      end

      result
    end

    def expand_once(source)
      return nil unless ReopeningCall.possible?(source)

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      calls = RbsInfer::Analyzer.find_all_nodes(parsed.value) { |node| reopening_block?(node) }
      replacements = outermost(calls).map { |call| replacement_for(source, call) }.compact
      return nil if replacements.empty?

      apply_replacements(source, replacements)
    end

    # A reopening call (`ReopeningCall.shape?`) whose receiver is a CONSTANT, so
    # it names its class outright. A non-constant receiver (`obj.class_eval`)
    # reopens whatever class the value happens to be, which the shape does not
    # say — except for `self.class` inside an instance method, where the
    # enclosing declaration says it and `SelfClassEvalExpander` reads it.
    def reopening_block?(node)
      ReopeningCall.shape?(node) && constant_receiver?(node.receiver)
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

      {
        start: call.location.start_offset,
        end: call.location.end_offset,
        text: BlockReopen.in_place(source: source, call: call, name: name),
      }
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
