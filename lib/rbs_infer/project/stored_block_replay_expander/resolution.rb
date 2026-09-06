# frozen_string_literal: true

require_relative "shapes"
require_relative "call_graph"

module RbsInfer::Project::StoredBlockReplayExpander
  # The last phase: which class each collected block actually lands on.
  #
  # The three phases were always there — the lexical walk fills the shapes, the
  # corpus walk merges other files' into them, and this reads them — and the
  # boundary between the last two was already written down as a `protected`
  # reader and an `absorb`. This is that boundary made into an object: a
  # `ShapeSet` and a `Declarations` in, replays and extensions out, and no way
  # to reach back into the walk that produced them
  # (felixefelip/rbs_infer#306).
  #
  # It answers TWO things from one traversal, and they are separate on purpose:
  # a block relocated onto a target, and an `extend` put on that same target.
  # One hook does both — `ActiveSupport::Concern#append_features` is the case —
  # so neither may count as evidence against the other, and a concern with a
  # `ClassMethods` and no `included do` must still be read.
  class Resolution
    include Shapes

    # `source` is the file being expanded, by IDENTITY: the collector keeps the
    # very string it was handed, and a block written in another file is resolved
    # here but emitted by that file's own run.
    def initialize(shapes:, names:, source:)
      @shapes = shapes
      @names = names
      @source = source
      @deferred_registry = Hash.new { |hash, key| hash[key] = [] }
      @extensions = []
      @graph = CallGraph.new(replay_methods: shapes.replay_methods, readers: shapes.readers,
                            inward_replays: shapes.inward_replays, literal_replays: shapes.literal_replays,
                            forwards: shapes.forwards, delegations: shapes.resolved_delegations,
                            storages: shapes.storages)
    end

    # The `extend`s the module calls put on their targets. Populated by `run`
    # alongside the replays it answers with: both are what a call site here does
    # to a class here, read off the same resolution.
    attr_reader :extensions

    # The replays this file emits, and — as a side effect read back through
    # `extensions` — the `extend`s its call sites put on their targets.
    def run
      providers = ancestry(@names.providers)
      register_deferrals(providers)

      # The own-block replays FIRST: one may create the very module the `extend`
      # below asks about, and a concern writes both halves — `class_methods do`
      # builds `ClassMethods`, `append_features` extends the host with it.
      # EVERY stored call, not only this file's. What a DSL call creates is a
      # fact about the file that wrote it — the same kind of fact as a
      # declaration, and absorbed the same way — while whether the block is
      # RELOCATED here is the separate question of whose file this is. Reading
      # only the local ones left a host unable to see the module its own concern
      # builds, so the `extend` that hands it over declined.
      resolved = @shapes.stored_calls.filter_map { |stored| resolve_own_block(stored, providers) }
                              .select { |replay| replay.source.equal?(@source) }

      @extensions = @shapes.module_calls.flat_map { |module_call| resolve_extensions(module_call, providers) }.uniq

      resolved += @shapes.module_calls.flat_map { |module_call| resolve_module_call(module_call, providers) }

      # Two module calls naming the same source in the same class body are one
      # replay written twice, not two — the block relocates to that class once.
      # Keyed on the block's own SOURCE as well as its offset, since two files
      # hold blocks at the same offset all the time and a location says nothing
      # about which file it indexes.
      resolved.uniq { |replay| [replay.target, replay.singleton, replay.source, replay.block.location.start_offset] }
    end

    private

    # The method Ruby splices an ancestor in, as the transcription names it.
    # Ours, not Ruby's: `rb_include_module` has no name at the Ruby level and
    # `append_features` is a hook an application overrides
    # (felixefelip/rbs_infer#311).
    SPLICE = "__rbs_infer__include_module"

    # `providers` grown by the module calls that splice a module into a
    # subject's SINGLETON — which is what `extend Foo` is, read rather than
    # recognised by its spelling.
    #
    # A fixpoint, because the table is both the question and the answer: finding
    # which method a call reaches needs the table, and reaching the splice grows
    # it. The seed needs no call at all — `Object#extend` is reachable from the
    # core chains, which come from the subject's kind — and the table only ever
    # gains entries, so its size bounds the loop.
    def ancestry(providers)
      loop do
        grown = false

        @shapes.module_calls.each { |call| splice(call, providers, local: true) { grown = true } }
        @shapes.foreign_module_calls.each { |call| splice(call, providers, local: false) { grown = true } }

        return providers unless grown
      end
    end

    # One module call's contribution to the table, yielding when it added
    # something.
    #
    # A LOCAL call is resolved against this file's declarations, which is the
    # scope its name was written in. A FOREIGN one is not: its name belongs to
    # the scope of the file that wrote it, and the corpus this file absorbed is
    # a wider world than that file could see. Reading `extend DSL` in a concern
    # that declares nothing, and picking the `Elsewhere::DSL` some third file
    # happens to declare, is choosing a namespace on evidence the writer never
    # had. So the written name is the key, and it matches whatever supplies
    # methods under exactly that name — or nothing, which changes no answer
    # (felixefelip/rbs_infer#268).
    def splice(call, providers, local:)
      argument = (local && @names.resolve(call.argument, call.subject)) ||
                 Declarations.written_constant(call.argument)
      return unless argument

      spliced_subjects(call.subject, call.method, argument, providers).each do |subject|
        yield if providers[argument].add?(subject)
      end
    end

    # The subjects whose singleton gains `argument`, following the call from
    # where it was written to the splice.
    #
    # Two objects travel together and SWAP at every hop, because a forward hands
    # the callee `self`: what was the receiver becomes the argument. For
    # `X.extend(M)` the transcription walks
    #
    #   X.extend(M)              receiver X            argument M
    #   M.extend_object(X)       receiver M            argument X
    #   X.singleton.include(M)   receiver singleton(X) argument M
    #   M.append_features(…)     receiver M            argument singleton(X)
    #   splice                   receiver singleton(X) argument M
    #
    # and the receiver it arrives with is the object that gained the module. A
    # plain `include Foo` walks the same chain and arrives at `Bar`, not
    # `singleton(Bar)`, which is why it says nothing about who can call what.
    #
    # Every forward is followed, not one: `include` hands its argument to
    # `included` as well, and that branch simply reaches no splice.
    def spliced_subjects(receiver, method, argument, providers, seen = Set.new)
      return [] unless seen.add?([receiver, method, argument])
      return [singleton_subject(receiver)].compact if method == SPLICE

      forwards_from(receiver, method, providers).flat_map do |forward|
        onward = forward.singleton ? Declarations.singleton_owner(argument) : argument
        spliced_subjects(onward, forward.callee, receiver, providers, seen)
      end.uniq
    end

    # The forwards of `method` as `receiver` would dispatch it — over the owners
    # that supply `receiver`, which for a singleton object is the class chain
    # every class object answers from.
    def forwards_from(receiver, method, providers)
      owners = if singleton_subject(receiver)
                 CORE_SELF_CHAINS.fetch("class", [])
               else
                 providers.select { |_, subjects| subjects.include?(receiver) }.keys
               end

      @shapes.forwards.select { |forward| owners.include?(forward.owner) && forward.method == method }
    end

    # The subject behind `singleton(Foo)`, or nil for anything else — including
    # a plain name, which is the whole distinction this pass turns on.
    def singleton_subject(name)
      name[/\Asingleton\((.+)\)\z/, 1]
    end

    # The block a DSL call runs where it stands, or nil when the file does not
    # decide it.
    #
    # The same call `resolve_module_call`'s chain treats as STORAGE, asked the other
    # question: not "which earlier block does this call apply", but "does the method
    # this call reaches run the block right here". A DSL may do either, and one
    # that does both is not a contradiction — the block runs now AND is kept for
    # later — so this is resolved on its own evidence rather than counted
    # against the storage path.
    #
    # Resolved for every stored call, wherever it was written — a foreign one
    # registers the module it CREATES and is then dropped by the caller, since
    # the file that wrote it reopens its own subject and emitting it here as
    # well would relocate the block twice. Identity, not equality, for the same
    # reason `StoredBlockReplayImplements` uses it: the collector keeps the very
    # string it was handed.
    def resolve_own_block(stored, providers)
      candidates = providers.select { |_, subjects| subjects.include?(stored.subject) }.keys.filter_map do |provider|
        replays = @shapes.resolved_own_replays.select { |own| own.owner == provider && own.method == stored.method }
        next unless replays.size == 1

        replay_where_written(stored, replays.first, providers)
      end.uniq

      # Two providers answering one call with two different targets is one
      # runtime dispatch this pass cannot pick a winner for — the same count
      # `resolve_module_call` declines on.
      candidates.first if candidates.size == 1
    end

    # The `Replay` an own-block DSL call stands for, or nil when its target is
    # not a type this file can name.
    #
    # `self` inside the DSL method is the SUBJECT — the class or module whose
    # body wrote the call — so that is both the target when the DSL replays onto
    # its own `self` and the namespace a `const_get` is looked up under.
    def replay_where_written(stored, own, providers)
      target = own.name ? named_constant(own, stored.subject) : stored.subject
      return nil unless target

      # A created namespace says its own keyword — `Module.new` is a module —
      # and is recorded, because nothing else in the project can answer for it
      # and the `extend` half of a concern asks.
      @names.record_created(target, own.creates) if own.name && own.creates
      kind = @names.kind_of(target)
      return nil unless kind

      Replay.new(target: target, block: stored.block, kind: kind, call: stored.method,
                 scope: stored.subject, in_method: nil, source: stored.source, singleton: own.singleton,
                 extended: handed_to_hosts?(target, stored.subject, providers))
    end

    # Whether a hook in `subject`'s provider chain hands this very module to
    # whoever mixes the subject in — `base.extend(const_get(:X))`, the other half
    # of what a concern does.
    #
    # Read from the SUBJECT's side, where the `include` naming the hosts is
    # written in their files rather than this one: what this file can say is that
    # the module is handed out, and to whom is the mixin graph's answer. Both
    # halves are needed and neither is a guess — the extend is read off the
    # provider's own source, exactly as `resolve_extensions` reads it from the
    # host's side.
    def handed_to_hosts?(target, subject, providers)
      owners = providers.select { |_, subjects| subjects.include?(subject) }.keys

      @shapes.resolved_inward_extends.any? do |extension|
        owners.include?(extension.owner) && named_constant(extension, subject) == target
      end
    end

    # What one written `apply` relocates.
    #
    # Per CALL SITE, which is the unit the question is actually asked about: an
    # `apply(Baz)` written in one class body relocates one block onto that one
    # class, and what would make it undecidable is two different blocks arriving
    # under it.
    #
    # Emphatically NOT per block. Grouping the answers by block and keeping only
    # the blocks with a single target read `Bar` and `BarOther` both applying
    # `Baz` as an ambiguity and dropped BOTH, so a source module used twice
    # relocated nothing — which is the shape `ActiveSupport::Concern` has, and
    # the common case rather than an exotic one. Nothing is ambiguous there:
    # each call site names its own target, and the block simply runs twice, as
    # it does at runtime (felixefelip/rbs_infer#263).
    def resolve_module_call(module_call, providers)
      source_subject = @names.resolve(module_call.argument, module_call.subject)
      return [] unless source_subject

      replays_landed(module_call.subject, module_call.method, source_subject, providers, Set.new)
    end

    # One application of a module to a class, as the replays it lands there —
    # none, one, or one per module the applied one was HOLDING
    # (felixefelip/rbs_infer#300).
    #
    # The DSL's own source is what decides between those. A deferring DSL asks
    # whether the target already holds its slot; when it does, this application
    # registers and lands nothing, and `register_deferrals` has recorded it.
    # When it does not, the registrations come back out — `recall`, on each
    # module held — and each is resolved AS a call site written here, which is
    # what it is: `base.include(dep)` is an `include` in the host's body that
    # the DSL wrote instead of the programmer.
    #
    # So a waypoint is never a target. `Post::Commentable`'s file registers the
    # shared concern and emits nothing; `Post`'s file drains it and the
    # `has_many` lands on `Post`, which is where it runs.
    #
    # `seen` guards the recursion rather than a depth limit: two concerns can
    # register each other, and a pair that does must not hang the pass.
    def replays_landed(subject, method, source_subject, providers, seen)
      return [] unless seen.add?([subject, source_subject])

      deferral = deferral_for(subject, method, source_subject, providers)
      return [] if deferral && holds_slot?(subject, deferral.slot, providers)

      replays = [direct_replay(subject, method, source_subject, providers)].compact
      return replays unless deferral

      replays + @deferred_registry[source_subject].flat_map do |held|
        replays_landed(subject, deferral.recall, held, providers, seen)
      end
    end

    # Which modules each waypoint is holding, read off every call site the
    # project writes.
    #
    # A registration is a fact about the module that made it, not about the file
    # asking — so this walks the absorbed call sites too, and the entries it
    # writes are read back by `replays_landed` in whatever file finally
    # closes the hop.
    def register_deferrals(providers)
      (@shapes.module_calls + @shapes.foreign_module_calls).each do |module_call|
        source_subject = @names.resolve(module_call.argument, module_call.subject)
        next unless source_subject

        deferral = deferral_for(module_call.subject, module_call.method, source_subject, providers)
        next unless deferral && holds_slot?(module_call.subject, deferral.slot, providers)

        registered = @deferred_registry[module_call.subject]
        registered << source_subject unless registered.include?(source_subject)
      end
    end

    # The deferral the DSL behind one application writes, or nil when it always
    # replays where it stands. Same two-sided walk `direct_replay` makes — the
    # one provider answers for the subject, the keeper for the module — because the
    # method that defers is the one the module's own provider supplies.
    def deferral_for(subject, method, source_subject, providers)
      subject_providers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      source_providers = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      found = subject_providers.product(source_providers).flat_map do |subject_provider, source_provider|
        @graph.keepers_for(subject_provider, method, source_provider).flat_map do |keeper_owner, keeper_method|
          @shapes.deferrals.select { |deferral| deferral.owner == keeper_owner && deferral.method == keeper_method }
        end
      end.uniq

      found.first if found.size == 1
    end

    # Whether `subject` holds the slot the DSL branches on — which is the branch
    # taken, evaluated per call site.
    #
    # Not by reading the predicate. What the predicate asks (`does base have
    # @_dependencies`) is answered by the method that PUTS it there — and by the
    # call site that RUNS that method. Both halves are needed, and the second is
    # the one this used to be missing: it asked only whether some DSL both
    # subjects extend had a method writing the slot onto a parameter, so a
    # `def self.setup(base)` nothing ever calls reported every extender of that
    # DSL as holding the slot. The answers were right for the DSLs we have, and
    # right by luck — the pass could not tell a hook from a method nobody calls
    # (felixefelip/rbs_infer#302).
    #
    # Read forwards instead, from the call site out: `extend Deferring` written
    # in `Example62::Middle` is a module call; the supplying module is `Object#extend`,
    # transcribed from `rb_obj_extend`, which forwards its argument to
    # `extend_object` and then `extended`; and `Deferring.extended` writes
    # `@deferred` onto its parameter. Every link is read off source — nothing
    # here spells `extend` or `extended`, and `keepers_for` is the same walk
    # `deferral_for` already makes for the block.
    #
    # A property of the SUBJECT alone, which is why the source subject the
    # callers used to pass is gone. The predicate is about the object the DSL was
    # handed; which module was being handed to it when the question came up
    # decides nothing.
    def holds_slot?(subject, slot, providers)
      subject_providers = providers.select { |_, subjects| subjects.include?(subject) }.keys

      (@shapes.module_calls + @shapes.foreign_module_calls).any? do |module_call|
        next false unless module_call.subject == subject

        argument = @names.resolve(module_call.argument, module_call.subject)
        next false unless argument

        source_providers = providers.select { |_, subjects| subjects.include?(argument) }.keys

        subject_providers.product(source_providers).any? do |subject_provider, source_provider|
          writes_slot?(@graph.keepers_for(subject_provider, module_call.method, source_provider), slot)
        end
      end
    end

    # Whether any of the methods a call reaches initialises `slot` on what it was
    # handed. The hooks arrive as `[owner, method]` pairs, which is what a
    # `SlotInit` is keyed by.
    def writes_slot?(hooks, slot)
      hooks.any? do |hook_owner, hook_method|
        @shapes.slot_inits.any? do |init|
          init.ivar == slot && init.owner == hook_owner && init.method == hook_method
        end
      end
    end

    # The one block an application relocates, or nil when the file does not
    # decide it.
    #
    # Two provider questions, not one. The supplying module is dispatched on the
    # SUBJECT (`banana` arrives in `Bar`'s body) and the callee it forwards
    # to on the ARGUMENT (`mod.send(:bananed, self)` runs on `Baz`), so the
    # two are answered by whatever supplies each — which need not be the
    # same module. Requiring one provider for both is what `ActiveSupport`'s
    # own shape breaks: `Module#include` reaches for `append_features`, a
    # method of the concern (felixefelip/rbs_infer#256).
    def direct_replay(subject, method, source_subject, providers)
      subject_providers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      source_providers = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      candidates = subject_providers.product(source_providers).filter_map do |subject_provider, source_provider|
        replay_for(subject, method, subject_provider, source_provider, source_subject)
      end

      # One block per call site. Two providers answering with two DIFFERENT
      # blocks is the ambiguity this pass declines — which of them a runtime
      # dispatch reaches is not a question the source answers. The same block
      # reached twice is no disagreement, so it is deduplicated rather than
      # counted.
      candidates = candidates.uniq do |candidate|
        [candidate.source, candidate.block.location.start_offset, candidate.singleton]
      end
      return nil unless candidates.size == 1

      candidates.first
    end

    # The `extend`s one module call puts on its target.
    #
    # The same walk `resolve_module_call` makes, over the same providers, and separate
    # from it on purpose: an `extend` and a block replay are two effects of one
    # hook — `ActiveSupport::Concern#append_features` does both — so neither may
    # count as evidence against the other. A concern with a `ClassMethods` and
    # no `included do` must still be read, and one with both must not decline
    # for having two answers.
    #
    # The count that DOES decide is between providers: two different modules
    # answering `included` for one subject is one runtime dispatch that this
    # pass cannot pick a winner for, so it says nothing. Several `extend`s from
    # one provider are not that — see `inward_extend_shapes`.
    def resolve_extensions(module_call, providers)
      source_subject = @names.resolve(module_call.argument, module_call.subject)
      return [] unless source_subject

      extensions_for(module_call.subject, module_call.method, source_subject, providers, Set.new)
    end

    # The `extend`s one application puts on its target, following the same
    # deferral the replays follow.
    #
    # It is one hook doing both, so it goes where the hook goes: a deferred
    # application ran neither the `class_eval` nor the `extend`, and the module
    # the waypoint was holding is extended onto the class that finally arrives.
    # Reading the two halves differently would say a concern's `class_methods`
    # reach a module its `included do` does not.
    def extensions_for(subject, method, source_subject, providers, seen)
      return [] unless seen.add?([subject, source_subject])

      deferral = deferral_for(subject, method, source_subject, providers)
      return [] if deferral && holds_slot?(subject, deferral.slot, providers)

      direct = direct_extensions(subject, method, source_subject, providers)
      return direct unless deferral

      direct + @deferred_registry[source_subject].flat_map do |held|
        extensions_for(subject, deferral.recall, held, providers, seen)
      end
    end

    def direct_extensions(subject, method, source_subject, providers)
      kind = @names.own_kind(subject)
      return [] unless kind

      subject_providers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      source_providers = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      answers = subject_providers.product(source_providers).filter_map do |subject_provider, source_provider|
        names = extension_names(subject_provider, method, source_provider, source_subject)
        names unless names.empty?
      end.uniq
      return [] unless answers.size == 1

      answers.first.map { |name| Extension.new(target: subject, kind: kind, name: name) }
    end

    # The modules reached from `owner#method` that a hook extends its argument
    # with. Same walk as `inward_slot` — every forward, resolved through the
    # ARGUMENT's provider — differing only in what the keeper turns out to do
    # with what it was handed.
    def extension_names(owner, method, source_provider, source_subject)
      @shapes.forwards.flat_map do |forward|
        next [] unless forward.owner == owner && forward.method == method

        keeper_owner, keeper_method = @graph.keeper(source_provider, forward.callee)
        next [] unless keeper_owner

        # `self` inside the keeper is the object the call was dispatched on,
        # which is the source subject — unless a delegation took the call
        # somewhere else, in which case `self` is the object it was handed to
        # and a `const_get` names that object's constants instead. Passing nil
        # is what declines those: the syntactic spelling still resolves, since
        # a written constant means the same thing wherever it is dispatched.
        under = keeper_owner == source_provider ? source_subject : nil
        @shapes.resolved_inward_extends.filter_map do |extension|
          next unless extension.owner == keeper_owner && extension.method == keeper_method

          extension_name(extension, under)
        end
      end.uniq
    end

    # The module an `InwardExtend` names, or nil when this call site does not
    # decide it.
    #
    # A name fetched as data is looked up under the `self` it was fetched from,
    # and it must actually BE there: `const_get(:ClassMethods)` on a concern
    # that declares none raises at runtime, which is why the source guards it
    # with `const_defined?`. Emitting the `extend` regardless would name a type
    # nothing declares.
    def extension_name(extension, under)
      name = named_constant(extension, under)
      name if name && @names.module?(name)
    end

    # The constant a shape names, resolved for one call site: a written one is
    # already the answer, and a fetched one is looked up under the `self` it was
    # fetched from — which must actually declare it, since `const_get` on a
    # module that does not raises at runtime.
    def named_constant(shape, under)
      return shape.name unless shape.dynamic
      return nil unless under

      name = "#{under}::#{shape.name}"
      # A constant the expression CREATES needs no prior declaration — being
      # undeclared is the normal state of one, and this pass emitting a reopening
      # for it is what declares it. `const_get` is the other case and keeps the
      # check: on a module nobody defined it raises, and the guard a DSL writes
      # around it says so.
      return name if shape.creates

      @names.kind_of(name) ? name : nil
    end

    def replay_for(subject, method, subject_provider, source_provider, source_subject)
      # Both directions answer with the SLOT — and with the object that owns
      # it, which is not always the provider: a delegating DSL method keeps
      # the block on something it holds. From there the chain is one and the
      # same: whoever fills that slot is the storage method, and the call the
      # source wrote under that name holds the block. Asking both and
      # requiring a single answer is what keeps a file that somehow reads as
      # both from being resolved by declaration order.
      slots = [@graph.outward_slot(subject_provider, method),
               @graph.inward_slot(subject_provider, method, source_provider)].compact.uniq
      # And the third way to reach a block: not through a slot at all,
      # because the replaying method wrote it in place. Counted together
      # with the slots, so a file reading as both still declines.
      literals = @graph.literal_replays_for(subject_provider, method, source_provider)
      return nil unless slots.size + literals.size == 1

      kind = @names.own_kind(subject)
      return nil unless kind

      if (literal = literals.first)
        return Replay.new(target: subject, block: literal.block, kind: kind,
                          call: literal.call, scope: literal.scope, in_method: literal.method,
                          source: literal.source, singleton: literal.singleton, extended: false)
      end

      storage_owner, ivar, singleton = slots.first
      # The SOURCE's provider, not the supplying module's: the name being looked up
      # is the one the source wrote in its own body.
      storage_method = @graph.storage_method_for(source_provider, storage_owner, ivar)
      return nil unless storage_method

      blocks = @shapes.stored_calls.select { |stored| stored.subject == source_subject && stored.method == storage_method }
      return nil unless blocks.size == 1

      Replay.new(target: subject, block: blocks.first.block, kind: kind,
                 call: storage_method, scope: blocks.first.subject, in_method: nil,
                 source: blocks.first.source, singleton: singleton, extended: false)
    end
  end
end
