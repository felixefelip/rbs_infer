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
      return [] unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return [] unless parsed.success?

      replays = StoredBlockReplayExpander::Collector.new(source, sources: sources).collect(parsed.value)

      per_block(written_here(replays, source)).filter_map do |entries|
        replay = entries.first
        next unless replay.scope

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
    end

    # The replays whose block is written in THIS file.
    #
    # Since felixefelip/rbs_infer#265 a replay may move a block from another
    # file — the host of a concern resolves one, and the block lives with the
    # concern. The annotation this sidecar places rides the block's own opener,
    # so it has to be injected into the file holding that block; an entry filed
    # under the host would name a scope the host does not contain and match
    # nothing there. Skipped rather than misfiled, which leaves `steep check`
    # reading such a block where it is written — the RBS half is unaffected,
    # since the expander moved it either way.
    #
    # Identity, not equality: `Collector` keeps the very string it was handed,
    # so the local replays carry this exact object and a foreign one cannot.
    def written_here(replays, source)
      replays.select { |replay| replay.source.equal?(source) }
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
