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
    # No `self` key: `@implements <Target>` already runs the block's `def`
    # bodies with an instance of `<Target>` as self, which is what a
    # `class_eval`ed def gets at runtime. The `class_methods do` entries need
    # that key because their self is the INCLUDER's singleton, a type the
    # `@implements` module does not name.
    def blocks_for(source:, sources:)
      return [] unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return [] unless parsed.success?

      replays = StoredBlockReplayExpander::Collector.new(source, sources: sources).collect(parsed.value)

      per_block(written_here(replays, source)).filter_map do |entries|
        replay = entries.first
        next unless replay.scope

        entry = { "call" => replay.call, "in" => "::#{replay.scope}", "implements" => implements(entries) }
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
      targets = entries.map { |replay| "::#{replay.target}" }.uniq
      targets.size == 1 ? targets.first : targets
    end
  end
end
