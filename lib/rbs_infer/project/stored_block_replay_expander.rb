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
  #
  # And the `extend` a hook writes alongside the replay — `base.extend(M)`,
  # which the same chain resolves and which reopens the same target, differing
  # only in that there is no block to move: the module is already written
  # somewhere and the target's SINGLETON gains it. It is the half of
  # `ActiveSupport::Concern` that makes a `ClassMethods` the host's class
  # methods, and it lives here rather than in an expander of its own because
  # every question it raises — who the target is, which module supplies the
  # hook, whether a delegation moved `self` — is one this chain already answers
  # (felixefelip/rbs_infer#268).
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
    # `extended` says the target is reached by EXTENDING whoever mixes the
    # scope in, rather than by being the scope itself: a hook in the scope's
    # provider chain hands its base this very module. It changes nothing about
    # where the block's `def`s go — that is `target` — and everything about the
    # `self` they run with, which is then the host's class object rather than an
    # instance of the module (felixefelip/rbs_infer#268).
    # `target` is where the block's `def`s LAND, which is not always where the
    # call site handed it: a DSL that defers registers the module on the target
    # and replays it on whoever includes THAT, so the collector follows the hop
    # and answers with the class the block runs on
    # (felixefelip/rbs_infer#300).
    Replay = Data.define(:target, :block, :kind, :call, :scope, :in_method, :source, :singleton, :extended)

    module_function

    # `sources` is a `Project::ConstantSources` — where the DSL's own methods
    # are declared, which need not be this file. Required, with
    # `ConstantSources::NONE` as the explicit way to say "no project": defaulted,
    # a caller that forgot it would quietly resolve less
    # (docs/engineering/required-threaded-deps.md).
    def expand(source, sources:, mixin_index:)
      # This file's own text is no longer the whole question. A concern writes
      # `base.class_eval do … end` in its own file and the `include` naming the
      # target is written in the host, which mentions no eval — so gating on the
      # local substring skipped exactly the file the block had to be moved INTO
      # (felixefelip/rbs_infer#265). The project-wide answer keeps what the gate
      # was for: a project that writes neither an eval nor an inward `extend`
      # anywhere still pays nothing.
      return nil unless possible?(source, sources)

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      collector = Collector.new(source, sources: sources)
      replays = collector.collect(parsed.value)
      extensions = collector.extensions
      return nil if replays.empty? && extensions.empty?

      apply_replays(source, replays, extensions, mixin_index)
    end

    # The block literals this file's storage slots hold, as
    # `{ owner => { ivar => [body source, …] } }` (felixefelip/rbs_infer#321).
    #
    # Read off the SAME replays the rewrite is built from, never re-derived: a
    # block the resolution declined does not reach a slot here either, so the
    # payload that lands in `sig/` and the relocation cannot disagree about
    # which block is which.
    #
    # Its own collection rather than another return value on `expand`, whose
    # contract stays one source in, one source out — this caller wants the map
    # and no rewrite. The corpus walk it repeats is memoized per file.
    def stored_block_bodies(source, sources:)
      return {} unless possible?(source, sources)

      parsed = Prism.parse(source)
      return {} unless parsed.success?

      collector = Collector.new(source, sources: sources)
      bodies_by_slot(collector.storages, collector.collect(parsed.value))
    end

    # Joins each slot to the blocks that pass through it.
    #
    # `Storage` names `(owner, method, ivar)` and a `Replay`'s `call` is that
    # same storage method — the name written on the block being moved — so the
    # method is the join and the replay is the evidence.
    #
    # Sliced against `replay.source` and not the file being expanded, for the
    # reason `Replay#source` exists at all: a location is a pair of offsets, and
    # a concern's block is written in the concern's file while the `include`
    # that resolves it is written in the host's.
    def bodies_by_slot(storages, replays)
      storages.each_with_object({}) do |storage, out|
        bodies = replays.select { |replay| replay.call == storage.method }
                        .filter_map { |replay| body_source(replay) }
                        .uniq
        next if bodies.empty?

        (out[storage.owner] ||= {})[storage.ivar] = bodies
      end
    end

    def body_source(replay)
      body = replay.block.body
      return nil unless body

      location = body.location
      replay.source.byteslice(location.start_offset, location.end_offset - location.start_offset)
    end

    # Whether a replay can be in this file at all — asked of the PROJECT, since
    # the DSL that relocates a block is routinely declared somewhere else.
    # Shared with `StoredBlockReplayImplements`, which reads the same replays and
    # must not skip a file this one would expand.
    def possible?(source, sources)
      source.include?("class_eval") || source.include?("module_eval") ||
        source.include?(RbsInfer::Project::ConstantSources::INWARD_EXTEND) ||
        sources.eval_anywhere? || sources.inward_extend_anywhere?
    end

    def apply_replays(source, replays, extensions, mixin_index)
      # A body-less block (`keep do end`) relocates to nothing, and asking it
      # for a location raises. Drop it before the uniqueness check reads one.
      replays = replays.select { |replay| replay.block.body }

      # One reopening per (block, target) PAIR, not per block. A block replayed
      # onto two classes is two reopenings and both are real — `Collector`
      # resolves each module call on its own, and two of them naming the
      # same source is what a module reused by two classes looks like. Keyed on
      # the block alone this declined the whole file for exactly that shape
      # (felixefelip/rbs_infer#263).
      #
      # The block's SOURCE is part of its identity, not only its offsets: two
      # blocks in two files are routinely at the same offset, and a location
      # carries no file to tell them apart.
      keys = replays.map { |replay| [replay.source, replay.block.body.location, replay.target, replay.singleton] }
      # The file's `extend`s survive an ambiguity among its BLOCKS. Which block
      # a name reaches and which module a hook extends with are answered by
      # different evidence, so a file that fails to decide the first has said
      # nothing about the second. With no extends this reads exactly as the
      # `return nil` it replaces — an empty reopening list declines below.
      replays = [] unless keys.uniq.size == replays.size

      # Sliced from the file the block was WRITTEN in, which is what makes
      # relocating a foreign block possible at all — reading these offsets
      # against the file being expanded cuts unrelated text.
      virtual_reopens = replays.filter_map do |replay|
        BlockReopen.appended(source: replay.source, block: replay.block, kind: replay.kind, target: replay.target,
                             singleton: replay.singleton, annotations: annotations_for(replay, mixin_index))
      end
      virtual_reopens += extensions.map { |extension| extension_reopen(extension) }
      virtual_reopens = BlockReopen.missing_from(source, virtual_reopens)
      return nil if virtual_reopens.empty?

      [source, virtual_reopens.join("\n")].join("\n")
    end

    # The `@type instance:` line a relocated block needs, or none.
    #
    # A block moved onto a class needs nothing: its `def`s are members of that
    # class and their self is an instance of it, which the reopening already
    # says. One moved into a module the host is HANDED — a hook doing
    # `base.extend(M)` — needs it: those bodies run on the host's class object,
    # and without saying so every call they make to one of the host's own class
    # methods resolves to nothing (felixefelip/rbs_infer#268).
    #
    # Written into the reopening rather than injected afterwards, because the
    # reopening is where it belongs and because `ModuleSelfTypes.inject` cannot
    # place it: its anchor puts lines inside a NESTED module's body, and this
    # one is compact and top-level, so the annotation would land at end of file
    # bound to nothing.
    def annotations_for(replay, mixin_index)
      parts = running_selves(replay, mixin_index)
      return [] if parts.empty?

      ["# @type instance: #{union(parts)}"]
    end

    # The selves a handed-out module's methods run with — `singleton(<host>) & <module>`,
    # one per class the mixin graph says mixes the scope in.
    #
    # Both terms earn their place. The singleton is where the host's own class
    # methods live, which is what these bodies reach for; the module keeps calls
    # BETWEEN the block's own methods resolving, whether or not the host's RBS
    # ends up naming it.
    #
    # One derivation, two consumers: this is also what the `blocks:` sidecar
    # records for `steep check`, and the two must not disagree about the self a
    # method has (see `StoredBlockReplayImplements`).
    def running_selves(replay, mixin_index)
      return [] unless replay.extended

      mixin_index.hosts_of(replay.scope).map { |host| "singleton(::#{host}) & ::#{replay.target}" }
    end

    # An intersection is only legal bare, so a union of them parenthesizes each.
    def union(parts)
      parts.size == 1 ? parts.first : parts.map { |part| "(#{part})" }.join(" | ")
    end

    # The reopening an inward `extend` stands for. Not a `BlockReopen`: there is
    # no block to slice and nothing to re-indent, only the one line the hook
    # runs — but it goes in the same place, for the same reason, and is dropped
    # on a second pass by the same `missing_from`.
    def extension_reopen(extension)
      "#{extension.kind} #{extension.target}\n#{BlockReopen::INDENT}extend #{extension.name}\nend\n"
    end
  end
end
