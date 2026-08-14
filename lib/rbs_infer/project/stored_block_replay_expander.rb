# frozen_string_literal: true

require "prism"
require_relative "block_reopen"

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

    # `call` is the STORAGE method's name (`bazingado`), not the replay's
    # (`bazinga`): it is the name written on the block being moved. `scope` is
    # the class/module that block is written IN (`Example29::Baz`), which is not
    # the `target` it is replayed onto. Together they point Steep at this one
    # block in the real source, which a name alone cannot do once a file writes
    # the same DSL call twice — see `StoredBlockReplayImplements`.
    Replay = Data.define(:target, :block, :kind, :call, :scope)

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
      # A body-less block (`keep do end`) relocates to nothing, and asking it
      # for a location raises. Drop it before the uniqueness check reads one.
      replays = replays.select { |replay| replay.block.body }

      # A source block can only be replayed against one statically known target.
      # Multiple targets are ambiguous at runtime, so Collector rejects them.
      return nil unless replays.map { |replay| replay.block.body.location }.uniq.size == replays.size

      virtual_reopens = replays.filter_map do |replay|
        BlockReopen.appended(source: source, block: replay.block, kind: replay.kind, target: replay.target)
      end
      virtual_reopens = BlockReopen.missing_from(source, virtual_reopens)
      return nil if virtual_reopens.empty?

      [source, virtual_reopens.join("\n")].join("\n")
    end
  end
end
