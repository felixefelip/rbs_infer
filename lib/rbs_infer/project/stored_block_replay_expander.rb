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
  #
  # `extend Builder` is one way for Source and Target to have those methods;
  # `class Source < Builder` (with `def self.keep`) is the other, and the call
  # sites read the same either way. Both are recognised.
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
    # `in_method` is the def the call sits inside, and is nil for a DSL block —
    # `bazingado do` is written in the module body, so the scope already picks
    # it out. A hook writes its block inside `def self.included` instead, where
    # the call is `class_eval` on a parameter: that name says nothing about
    # which block is meant, so the def is what tells two of them apart
    # (felixefelip/rbs_infer#260).
    Replay = Data.define(:target, :block, :kind, :call, :scope, :in_method)

    module_function

    # `sources` is a `Project::ConstantSources` — where the DSL's own methods
    # are declared, which need not be this file. Required, with
    # `ConstantSources::NONE` as the explicit way to say "no project": defaulted,
    # a caller that forgot it would quietly resolve less
    # (docs/engineering/required-threaded-deps.md).
    def expand(source, sources:)
      return nil unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      replays = Collector.new(source, sources: sources).collect(parsed.value)
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
