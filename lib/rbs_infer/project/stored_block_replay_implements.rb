# frozen_string_literal: true

require "prism"
require_relative "stored_block_replay_expander"

module RbsInfer::Project
  # The `blocks:` sidecar entries that tell Steep who a stored, later-replayed
  # block really defines its methods on (felixefelip/rbs_infer#238).
  #
  # `StoredBlockReplayExpander` answers that for RBS *generation*: it moves the
  # block's body to the `class_eval` target so `greet` is emitted on `Bar`. But
  # `steep check` reads the REAL file, where the `def` still sits lexically in
  # `Baz`'s body — so Steep attributes it to `Baz` and reports a method that no
  # RBS declares. The relocation exists only in memory and never reaches it.
  #
  # `# @implements <Target>` on the block's opener is what closes that gap: it
  # rebinds the block body's module context, which is precisely what decides
  # where a `def` attaches. Steep's `Source::ModuleSelfTypes` places the comment
  # from the sidecar; this only decides the *what*.
  #
  # The target comes from `StoredBlockReplayExpander::Collector` — the same
  # object that decides where the RBS body is moved — so the sidecar and the
  # emitted RBS cannot disagree about which class gets the method.
  #
  # Core, not an extension, for the same reason the expander is: `class_eval` is
  # plain Ruby, so a project gets this whether or not it uses a framework. Only
  # the sidecar's DELIVERY is framework-shaped (a rake task), and that lives in
  # `Extensions::Rails::ModuleSelfTypeGenerator`, which calls in here.
  module StoredBlockReplayImplements
    module_function

    # @param source [String] the file's source
    # @return [Array<Hash>] `[{ "call" => "<storage method>", "in" => "::<Scope>",
    #   "implements" => "::<Target>" }]`, one per stored block whose replay
    #   target is decided, else `[]`.
    #
    # `in` is the class/module the block is WRITTEN in, and it is what makes one
    # DSL name usable twice in a file: a call name alone cannot tell `bazingado
    # do` in `Baz` (replayed onto `Bar`) from the one in `BazOther` (replayed
    # onto `BarOther`), and Steep would put both entries on both blocks.
    # Requires felixefelip/steep#145; before it this had to decline such a file
    # entirely and neither block was checked against its real definee.
    #
    # Not the block's LINE, which is the obvious key and the wrong one: Steep
    # applies the module-wide annotations first and those may add lines, so a
    # line measured against the real file no longer points at the same call by
    # the time the block entries are read. A scope survives that rewrite.
    #
    # A `self` key only where `@implements` is not the whole answer. For a
    # `class_eval`ed block it is: the bodies run with an instance of `<Target>`,
    # which is what they get at run time. For a block whose target is HANDED to
    # the host — a hook doing `base.extend(M)` — it is not: the bodies run on
    # the host's class object, where the host's own class methods live, and
    # naming only `M` type-checks them against a self they never have.
    #
    # `mixin_index` is required for that, with no default. The hosts are the
    # other half of the answer and they are written in THEIR files, not this
    # one; a caller that forgot to thread it would emit an entry that is right
    # about the module and silent about the self, which is the silent-wrong case
    # (docs/engineering/required-threaded-deps.md).
    def blocks_for(source:, sources:, mixin_index:)
      written_here(blocks_by_source(source: source, sources: sources, mixin_index: mixin_index), source)
    end

    # Every entry this file's replays call for, filed under the source each
    # block is WRITTEN in — which need not be this one.
    #
    # A concern is the ordinary case of the two being different: the `included
    # do` is written with the concern and the `include` that decides its target
    # is written in the host, so only the host's file resolves the replay and
    # only the concern's file can carry the annotation. Answering with just this
    # file's own blocks left that pair with nobody to write the entry — the host
    # knew the target and had no block, the concern held the block and could not
    # name a target — and `steep check` went on reading the `def` where it is
    # written, reporting a method no RBS declares
    # (felixefelip/rbs_infer#289).
    #
    # Keyed by IDENTITY on the source string, not by its content: `Collector`
    # keeps the very string it was handed, and two files with identical text are
    # two files.
    #
    # @return [Hash{String => Array<Hash>}] block source => entries
    def blocks_by_source(source:, sources:, mixin_index:)
      # The expander's gate, not a narrower one of our own. A concern writes
      # `class_methods do` and no eval at all — the eval is in the DSL, declared
      # somewhere else entirely — so asking this file's own text skipped exactly
      # the files whose blocks needed annotating (felixefelip/rbs_infer#268).
      return {} unless StoredBlockReplayExpander.possible?(source, sources)

      parsed = Prism.parse(source)
      return {} unless parsed.success?

      replays = StoredBlockReplayExpander::Collector.new(source, sources: sources).collect(parsed.value)

      by_source(replays).each_with_object({}.compare_by_identity) do |(written_in, group), table|
        entries = per_block(group).filter_map { |per| entry_for(per, mixin_index) }
        table[written_in] = entries if entries.any?
      end
    end

    # One block's entry, or nothing when the file does not say where the block
    # is written.
    def entry_for(entries, mixin_index)
      replay = entries.first
      return unless replay.scope

      entry = { "call" => replay.call, "in" => "::#{replay.scope}", "implements" => implements(entries) }
      if (running_self = handed_self(entries, mixin_index))
        entry["self"] = running_self
      end
      # Only for a block written inside a def. Emitting it as nil for the DSL
      # shape would put a key in every sidecar entry ever written, to say
      # nothing.
      entry["method"] = replay.in_method if replay.in_method
      entry
    end

    # Merges the entries two files wrote about ONE block — two hosts including
    # one concern, which is one block replayed onto two classes and so is one
    # entry naming both. Within a file `implements` already answers that; across
    # files the entries are built by separate passes, and only the sidecar sees
    # them together.
    #
    # Keyed on the block's identity as the sidecar states it — the call, the
    # scope it is written in, and the def it sits inside — since that is exactly
    # what Steep matches an entry against.
    def merge(entries)
      entries.group_by { |entry| entry.values_at("call", "in", "method") }.map do |_, group|
        merged = group.first.dup
        targets = group.flat_map { |entry| Array(entry["implements"]) }.uniq
        merged["implements"] = targets.size == 1 ? targets.first : targets
        selves = group.filter_map { |entry| entry["self"] }.uniq
        merged["self"] = StoredBlockReplayExpander.union(selves) if selves.any?
        merged
      end
    end

    # The replays grouped by the source their block is written in.
    def by_source(replays)
      replays.each_with_object({}.compare_by_identity) do |replay, groups|
        (groups[replay.source] ||= []) << replay
      end
    end

    # The entries for blocks written in THIS file.
    #
    # Identity, not equality: `Collector` keeps the very string it was handed,
    # so the local replays carry this exact object and a foreign one cannot.
    def written_here(table, source)
      table.fetch(source, [])
    end

    # The replays grouped by the BLOCK they move, since that is what an entry
    # speaks about: the annotation rides one block's opener, so every target
    # that block is replayed onto has to be named in that one entry.
    def per_block(replays)
      replays.group_by { |replay| replay.block.location.start_offset }.values
    end

    # Every target the block defines its methods on. A LIST once there is more
    # than one, which `@implements` now takes and Steep checks the body against
    # one by one — a block replayed onto two classes runs twice, and checking it
    # against one of them says nothing about the other (felixefelip/steep#149).
    #
    # A lone target stays a plain string: it is what every sidecar written so
    # far says, it reads better, and Steep takes either.
    def implements(entries)
      targets = entries.map { |replay| name_for(replay) }.uniq
      targets.size == 1 ? targets.first : targets
    end

    # `singleton(::Bar)` for a block replayed onto the target's singleton, which
    # is what `@implements` has to name for the `def`s to be checked against the
    # method table they actually land in — `Bar.age`, not `Bar#age`. Needs
    # felixefelip/steep#152; before it, `@implements` could name only a module,
    # so the singleton half of a `class_methods`-shaped DSL had no annotation to
    # write and its `def`s were read where they are written
    # (felixefelip/rbs_infer#267).
    # The self a handed-out module's methods actually run with, for `steep
    # check` to read.
    #
    # `StoredBlockReplayExpander.running_selves` is the derivation, called
    # rather than repeated: the expander writes the same answer into the
    # reopening it emits, and the two must not disagree about the self one
    # method has. Nothing when no replay here is handed out, and nothing when
    # the mixin graph names no host — an unmixed module's methods run with a
    # self this pass cannot state, and naming the module alone would be a wrong
    # answer rather than a partial one.
    def handed_self(entries, mixin_index)
      parts = entries.flat_map { |replay| StoredBlockReplayExpander.running_selves(replay, mixin_index) }.uniq
      return nil if parts.empty?

      StoredBlockReplayExpander.union(parts)
    end

    def name_for(replay)
      replay.singleton ? "singleton(::#{replay.target})" : "::#{replay.target}"
    end
  end
end
