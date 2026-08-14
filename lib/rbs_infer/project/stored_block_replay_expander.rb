# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # Moves a block's *definition site* to the class/module that later evaluates
  # it. Ruby's `class_eval(&stored_block)` runs `def`s in that block against the
  # receiver, not the object whose class body happened to contain the block.
  #
  # The direct spelling (`Widget.class_eval do … end`) is handled by
  # ClassEvalExpander. This is the equally-static indirect spelling:
  #
  #   module Builder
  #     attr_reader :body
  #     def keep(&block) = @body = block
  #     def apply(source) = class_eval(&source.body)
  #   end
  #
  #   module Source
  #     extend Builder
  #     keep { def installed; end }
  #   end
  #
  #   class Target
  #     extend Builder
  #     apply(Source)
  #   end
  #
  # It expands that to a virtual reopening of Target containing `installed`.
  # ClassMemberCollector deliberately ignores arbitrary blocks, so the original
  # lexical call site remains available as type evidence without emitting the
  # method on Source. This is plain Ruby rather than a framework convention, so
  # it lives in Project alongside ClassEvalExpander.
  #
  # Deliberately conservative: a chain must name one storage method, one reader,
  # one stored block, and one constant target. Any ambiguity declines the replay.
  #
  # Recognising the chain is `Collector`'s job (with `ReaderCollector` for the
  # `attr_reader` half); this module is only the rewrite it decides on.
  module StoredBlockReplayExpander
    REPLAY_METHODS = %i[class_eval module_eval].freeze

    Replay = Data.define(:target, :block, :kind)

    module_function

    def expand(source)
      return nil unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      replays = Collector.new(source).collect(parsed.value)
      return nil if replays.empty?

      apply_replays(source, replays)
    end

    def apply_replays(source, replays)
      # A source block can only be replayed against one statically known target.
      # Multiple targets are ambiguous at runtime, so Collector rejects them.
      return nil unless replays.map { |replay| replay.block.body.location }.uniq.size == replays.size

      virtual_reopens = replays.map do |replay|
        body = replay.block.body
        body_source = source.byteslice(body.location.start_offset, body.location.end_offset - body.location.start_offset)
        # Prism's body range starts at its first token, dropping the whitespace
        # that indented that line in the source. The virtual reopening is
        # top-level, so normalize that common margin to its conventional two
        # spaces while preserving every indentation level beneath it.
        first_line_indent = line_indent(source, body.location.start_offset)
        "#{replay.kind} #{replay.target}\n#{reindent_body(body_source, first_line_indent)}\nend\n"
      end

      [source, virtual_reopens.join("\n")].join("\n")
    end

    def line_indent(source, offset)
      scan = offset
      scan -= 1 while scan.positive? && [" ", "\t"].include?(source.byteslice(scan - 1, 1))
      return "" unless scan.zero? || source.byteslice(scan - 1, 1) == "\n"

      source.byteslice(scan, offset - scan)
    end

    def reindent_body(body_source, source_indent)
      return "  #{body_source}" if source_indent.empty?

      # The first line starts at Prism's first token and therefore has no
      # source margin in `body_source`; following lines still have it.
      ["  ", body_source.gsub(/(?<=\n)#{Regexp.escape(source_indent)}/, "  ")].join
    end
  end
end
