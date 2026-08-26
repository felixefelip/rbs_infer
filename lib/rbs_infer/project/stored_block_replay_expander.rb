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
  # one stored block, and one constant target PER CALL SITE. Any ambiguity
  # declines the replay — but a source applied from two class bodies is not one:
  # each site names its own target and the block runs on both, so both
  # reopenings are emitted (felixefelip/rbs_infer#263).
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
    # `source` is the file `block` was sliced from, which need NOT be the file
    # being expanded: a concern's block is written where the concern is, and the
    # `include` naming its target is written in the host. A location is only a
    # pair of offsets, so the string they index has to travel with them
    # (felixefelip/rbs_infer#265).
    # `singleton` says which of the target's two method tables the block's
    # `def`s land in — its own, or the class object's. `base.class_eval` and
    # `base.singleton_class.class_eval` are the same relocation onto the same
    # target and differ only in that, which is the difference between the RBS
    # reading `def age` and reading `def self.age`
    # (felixefelip/rbs_infer#267).
    Replay = Data.define(:target, :block, :kind, :call, :scope, :in_method, :source, :singleton)

    module_function

    # `sources` is a `Project::ConstantSources` — where the DSL's own methods
    # are declared, which need not be this file. Required, with
    # `ConstantSources::NONE` as the explicit way to say "no project": defaulted,
    # a caller that forgot it would quietly resolve less
    # (docs/engineering/required-threaded-deps.md).
    def expand(source, sources:)
      # This file's own text is no longer the whole question. A concern writes
      # `base.class_eval do … end` in its own file and the `include` naming the
      # target is written in the host, which mentions no eval — so gating on the
      # local substring skipped exactly the file the block had to be moved INTO
      # (felixefelip/rbs_infer#265). The project-wide answer keeps what the gate
      # was for: a project with no eval anywhere still pays nothing.
      return nil unless source.include?("class_eval") || source.include?("module_eval") ||
                        sources.eval_anywhere?

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

      # One reopening per (block, target) PAIR, not per block. A block replayed
      # onto two classes is two reopenings and both are real — `Collector`
      # resolves each apply call site on its own, and two of them naming the
      # same source is what a module reused by two classes looks like. Keyed on
      # the block alone this declined the whole file for exactly that shape
      # (felixefelip/rbs_infer#263).
      #
      # The block's SOURCE is part of its identity, not only its offsets: two
      # blocks in two files are routinely at the same offset, and a location
      # carries no file to tell them apart.
      keys = replays.map { |replay| [replay.source, replay.block.body.location, replay.target, replay.singleton] }
      return nil unless keys.uniq.size == replays.size

      # Sliced from the file the block was WRITTEN in, which is what makes
      # relocating a foreign block possible at all — reading these offsets
      # against the file being expanded cuts unrelated text.
      virtual_reopens = replays.filter_map do |replay|
        BlockReopen.appended(source: replay.source, block: replay.block, kind: replay.kind, target: replay.target,
                             singleton: replay.singleton)
      end
      virtual_reopens = BlockReopen.missing_from(source, virtual_reopens)
      return nil if virtual_reopens.empty?

      [source, virtual_reopens.join("\n")].join("\n")
    end
  end
end
