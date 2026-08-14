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
    # @return [Array<Hash>] `[{ "call" => "<storage method>", "implements" =>
    #   "::<Target>" }]`, one per stored block whose replay target is decided,
    #   else `[]`.
    #
    # No `self` key: `@implements <Target>` already runs the block's `def`
    # bodies with an instance of `<Target>` as self, which is what a
    # `class_eval`ed def gets at runtime. The `class_methods do` entries need
    # that key because their self is the INCLUDER's singleton, a type the
    # `@implements` module does not name.
    def blocks_for(source:)
      return [] unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return [] unless parsed.success?

      replays = StoredBlockReplayExpander::Collector.new(source).collect(parsed.value)
      return [] if replays.empty?

      entries_for(parsed.value, replays)
    end

    # Steep matches a `blocks` entry by CALL NAME alone (every receiverless
    # `name do … end` in the file gets the annotation), so a name written twice
    # cannot be annotated: the two blocks may well have different targets, and
    # both would receive both entries. Emit only the names written once, and
    # count them the way Steep does rather than from the replays — a second
    # block that the Collector declined is still a second block to Steep.
    def entries_for(root, replays)
      counts = block_call_counts(root)

      replays.filter_map do |replay|
        next unless counts[replay.call] == 1

        { "call" => replay.call, "implements" => "::#{replay.target}" }
      end.uniq
    end

    def block_call_counts(root)
      RbsInfer::Analyzer.find_all_nodes(root) do |node|
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.is_a?(Prism::BlockNode)
      end.each_with_object(Hash.new(0)) { |node, counts| counts[node.name.to_s] += 1 }
    end
  end
end
