# frozen_string_literal: true

module RbsInfer::Project::StoredBlockReplayExpander
  # Where a DSL call ENDS UP, walked over the shapes a file was read as writing.
  #
  # One question, asked from an apply call site: the applier forwards the
  # argument somewhere, that somewhere may delegate again, and whatever it
  # finally reaches either holds a block in a slot or runs one where it stands.
  # Following that is a graph walk over the collected shapes — forwards to
  # keepers, keepers to slots, slots to the storage method that fills them —
  # and it is the whole content of this class (felixefelip/rbs_infer#305).
  #
  # Declining is how it answers an ambiguity, everywhere and for one reason:
  # which method a runtime dispatch reaches is not a question the source
  # settles, so two candidates answer nothing rather than pick. Every `size == 1`
  # below is that rule.
  #
  # Built from the shapes rather than reaching for them, and built LATE — once
  # the delegations are resolved, since `keeper` reads them and a raw delegation
  # names a constant that may not have resolved yet.
  #
  # `dsl_providers` deliberately did NOT come along, though it is the other half
  # of "which DSL answers this call": it reads the file's declarations, extends
  # and superclasses — the state the VISITOR writes — where everything here
  # reads the method shapes. Two disjoint sets of state in one object would be a
  # worse seam than the one it removes; it belongs with the lexical scope.
  class DslGraph
    def initialize(replay_methods:, readers:, inward_replays:, literal_replays:,
                   forwards:, delegations:, storages:)
      @replay_methods = replay_methods
      @readers = readers
      @inward_replays = inward_replays
      @literal_replays = literal_replays
      @forwards = forwards
      @delegations = delegations
      @storages = storages
    end

    # The slot behind `class_eval(&param.reader)`, when `method` is itself the
    # replay: the reader names it, and an `attr_reader` in the same owner says
    # which ivar the reader reaches. Recognising the reader explicitly is what
    # keeps an arbitrary method named `body` from being read as an accessor.
    def outward_slot(owner, method)
      replays = @replay_methods.select { |replay| replay.owner == owner && replay.method == method }
      return nil unless replays.size == 1

      ivars = @readers.select { |reader_owner, name, _| reader_owner == owner && name == replays.first.reader }
      ivars = ivars.map(&:last).uniq
      [owner, ivars.first, replays.first.singleton] if ivars.size == 1
    end

    # The slot behind `param.class_eval(&@ivar)`, when `method` only FORWARDS to
    # the replay. One hop, not a chain: each additional link is another place a
    # runtime value could be substituted for the constant we resolved, and this
    # pass has no way to tell that it wasn't.
    # Every forward the method writes is asked, and the ones leading nowhere
    # simply answer nothing: `include` hands the argument to `append_features`
    # as well, and that method keeps no block, so it contributes no slot. The
    # count that decides ambiguity is therefore the number of forwards that
    # reach a REPLAY, not the number written — a DSL applier is free to send its
    # argument other messages on the way (felixefelip/rbs_infer#259).
    def inward_slot(owner, method, source_provider)
      slots = keepers_for(owner, method, source_provider).filter_map do |keeper_owner, keeper_method|
        replays = @inward_replays.select { |replay| replay.owner == keeper_owner && replay.method == keeper_method }
        [keeper_owner, replays.first.ivar, replays.first.singleton] if replays.size == 1
      end.uniq

      slots.first if slots.size == 1
    end

    # The replays reached from `owner#method` that carry their own block. Same
    # walk as `inward_slot` — every forward, resolved through the ARGUMENT's
    # provider — differing only in what the keeper turns out to hold.
    def literal_replays_for(owner, method, source_provider)
      keepers_for(owner, method, source_provider).filter_map do |keeper_owner, keeper_method|
        replays = @literal_replays.select { |replay| replay.owner == keeper_owner && replay.method == keeper_method }
        replays.first if replays.size == 1
      end.uniq
    end

    # The methods `owner#method` forwards its argument to, as
    # `[[owner, method]]`.
    #
    # The callee runs on the ARGUMENT, so it is the argument's provider that has
    # to supply it — reading it off the forward's own owner only works while one
    # module happens to hold both halves of the DSL. Every forward is asked and
    # the ones leading nowhere answer nothing: `include` hands the argument to
    # `included` as well, and a DSL is free to send its argument other messages
    # on the way (felixefelip/rbs_infer#259).
    def keepers_for(owner, method, source_provider)
      @forwards.filter_map do |forward|
        next unless forward.owner == owner && forward.method == method

        keeper_owner, keeper_method = keeper(source_provider, forward.callee)
        [keeper_owner, keeper_method] if keeper_owner
      end.uniq
    end

    # Where `owner#method` actually keeps things. Usually `owner` itself; one
    # owner further along when the method delegates, because then it holds
    # nothing and the block ends up on the object it hands the call to.
    #
    # One hop, for the same reason `inward_slot` takes one: each further link is
    # another place a runtime value could stand in for the constant we resolved.
    # Two delegations under one name answer nothing decidable.
    def keeper(owner, method)
      delegations = @delegations.select { |it| it.owner == owner && it.method == method }
      return [owner, method] if delegations.empty?
      return [nil, nil] unless delegations.size == 1

      [delegations.first.target, delegations.first.callee]
    end

    # The one method in `storage_owner` that fills `ivar`, reported under the
    # name a subject of `provider` writes to reach it — the other half of the
    # join, since that name is what the source's block was written under.
    # Exactly one, and it must fill exactly that one slot: a method storing into
    # two ivars cannot say which block a later replay is asking for.
    def storage_method_for(provider, storage_owner, ivar)
      entries = @storages.group_by { |storage| [storage.owner, storage.method] }.select do |(owner, _), storages|
        owner == storage_owner && storages.size == 1 && storages.first.ivar == ivar
      end
      return nil unless entries.size == 1

      names = written_names(provider, storage_owner, entries.keys.first.last)
      names.first if names.size == 1
    end

    # What a subject extending `provider` writes to reach `storage_owner#method`.
    # The keeper's own name when the provider IS the keeper; the delegating
    # method's name when it is not. Reading the keeper's name in both cases only
    # works while the two happen to be spelled alike — rename the held object's
    # method and nothing about the program changes, so nothing about the answer
    # may either.
    def written_names(provider, storage_owner, storage_method)
      names = []
      names << storage_method if provider == storage_owner

      @delegations.each do |delegation|
        next unless delegation.owner == provider
        next unless delegation.target == storage_owner && delegation.callee == storage_method

        names << delegation.method
      end

      names.uniq
    end
  end
end
