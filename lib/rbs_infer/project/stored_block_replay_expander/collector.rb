# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../ast/constant_reference"
require_relative "../../inference/send_call"
require_relative "../constant_sources"
require_relative "shapes"
require_relative "declarations"
require_relative "corpus"
require_relative "dsl_graph"
require_relative "node_reading"
require_relative "shape_reader"
require_relative "deferral_reader"

module RbsInfer::Project::StoredBlockReplayExpander
  # Collects declarations and class-body calls in one lexical pass. It keeps
  # syntax, not guessed types: resolving `Foo` in `extend Foo` and `Baz` in
  # `apply(Baz)` uses the declarations that are actually present in the file.
  class Collector < Prism::Visitor
    # The structs this pass collects, and the two core-ancestor tables it reads
    # them against. Declarations rather than behaviour, so they are declared
    # somewhere else (felixefelip/rbs_infer#304).
    include Shapes

    # `sources` is required, and `ConstantSources::NONE` is the way to say "no
    # project here". A DSL whose methods are declared in another file resolves
    # to nothing without it and reports nothing about why, which is the
    # silent-wrong case (docs/engineering/required-threaded-deps.md).
    def initialize(source, sources:)
      @source = source
      @sources = sources
      @method_depth = 0
      # Everything this file declares and what follows from it: the scope walk,
      # the kinds, the extends, the superclasses, and the provider table they
      # add up to (felixefelip/rbs_infer#305).
      @names = Declarations.new
      @storages = []
      @readers = []
      @replay_methods = []
      @inward_replays = []
      # Raw like `@delegations`: reading a deferral needs the `attr_reader`s,
      # which are collected in a second lexical walk once every declaration is
      # known, so the method bodies are kept and read then.
      @deferral_shapes = []
      @deferrals = []
      @slot_inits = []
      # Which modules each waypoint is holding for later — filled once every
      # apply call is known, since the registration and the drain are routinely
      # written in two different files.
      @deferred_registry = Hash.new { |hash, key| hash[key] = [] }
      # Raw like `@delegations`, and resolved the same way: a constant written
      # in a hook's body may name a module declared later in the file.
      @inward_extends = []
      @resolved_inward_extends = []
      # Raw and resolved like the extends above, and for the same reason: the
      # constant a DSL names may be declared further down its own file.
      @own_replays = []
      @resolved_own_replays = []
      @extensions = []
      # Absorbed from another file like the shapes above, but only because each
      # one carries the source it was sliced from. Without that they could not
      # be: a block is a pair of offsets, and reading them against the wrong
      # file cuts the wrong text (felixefelip/rbs_infer#265).
      @literal_replays = []
      @forwards = []
      # Raw like `@extends`/`@superclasses`, for the same reason: the constant
      # is resolved once every declaration in the file is known.
      @delegations = []
      @resolved_delegations = []
      @stored_calls = []
      @apply_calls = []
      # The apply calls of the files this one absorbs. Kept apart from
      # `@apply_calls` because they are read for ONE question — which modules a
      # waypoint is holding — and never emitted: the rewrite moves a block into
      # this source, and a call site in another file names a target this file
      # cannot reopen.
      @foreign_applies = []
      super()
    end

    def collect(root)
      root.accept(self)
      absorb_external_shapes
      resolve_replays
    end

    # Everything this file says about method shapes, for a collector reading it
    # on another file's behalf. Its delegations are resolved here, against the
    # declarations of the file they were written in — which is the only place
    # the constant they name can be looked up.
    def collect_shapes(root)
      root.accept(self)
      collect_readers_from_source
      @deferrals.concat(resolve_deferrals)
      @resolved_delegations = resolve_delegations
      @resolved_inward_extends = resolve_inward_extends
      @resolved_own_replays = resolve_own_replays
      # Who can call whose DSL, as THIS file writes it. A shape is only half of
      # what another file needs: `extend ActiveSupport::Concern` is written in
      # the concern, and without it a host holding the concern's shapes still
      # cannot say which owner supplies them.
      @providers = @names.providers
      self
    end

    # The `extend`s the apply calls in this file put on their targets. Populated
    # by `collect`, alongside the replays it answers with: both are what a call
    # site here does to a class here, read off the same resolution.
    attr_reader :extensions

    protected

    attr_reader :storages, :readers, :replay_methods, :inward_replays, :forwards, :resolved_delegations,
                :literal_replays, :stored_calls, :resolved_inward_extends,
                :resolved_own_replays, :providers, :deferrals, :slot_inits, :apply_calls

    # What an ABSORBING collector reads off this one, answered by the
    # declarations rather than kept a second time.
    def declaration_kinds
      @names.kinds
    end

    public

    def visit_class_node(node)
      @names.enter(node) { super }
    end

    def visit_module_node(node)
      @names.enter(node) { super }
    end

    def visit_def_node(node)
      collect_method_shape(node) if @names.current_scope
      @method_depth += 1
      super
    ensure
      @method_depth -= 1
    end

    def visit_call_node(node)
      collect_class_body_call(node) if @names.current_scope && @method_depth.zero?
      super
    end

    private

    def collect_method_shape(node)
      owner = @names.owner_for(node)
      return unless owner

      params = node.parameters
      block_name = params&.block&.name&.to_s
      method_name = node.name.to_s

      if block_name && (ivar = ShapeReader.stored_block_ivar(node.body, block_name))
        @storages << Storage.new(owner: owner, method: method_name, ivar: ivar)
      end

      if (replay = ShapeReader.replay_shape(node.body))
        parameter, reader, singleton = replay
        @replay_methods << ReplayMethod.new(owner: owner, method: method_name, parameter: parameter, reader: reader,
                                            singleton: singleton)
      end

      parameters = NodeReading.handed_names(node.body, NodeReading.parameter_names(params))

      if (inward = ShapeReader.inward_replay_shape(node.body, parameters))
        parameter, ivar, singleton = inward
        @inward_replays << InwardReplay.new(owner: owner, method: method_name, parameter: parameter, ivar: ivar,
                                            singleton: singleton)
      end

      # Kept rather than read: the slot a deferral registers into may be reached
      # through an `attr_reader`, and no reader is known until the second walk.
      @deferral_shapes << [owner, method_name, node.body, parameters]

      ShapeReader.slot_init_shapes(node.body, parameters).each do |parameter, ivar|
        @slot_inits << SlotInit.new(owner: owner, method: method_name, parameter: parameter, ivar: ivar)
      end

      if (own = ShapeReader.own_block_replay_shape(node.body, block_name))
        name, dynamic, creates, singleton = own
        @own_replays << [owner, method_name, name, dynamic, creates, singleton]
      end

      ShapeReader.inward_extend_shapes(node.body, parameters).each do |parameter, name, dynamic, creates|
        @inward_extends << [owner, method_name, parameter, name, dynamic, creates]
      end

      if (literal = ShapeReader.literal_replay_shape(node.body, parameters))
        call, block, singleton = literal
        @literal_replays << LiteralReplay.new(owner: owner, method: method_name, scope: @names.current_scope,
                                              call: call, block: block, source: @source, singleton: singleton)
      end

      if (delegation = ShapeReader.delegation_shape(node))
        target, callee = delegation
        @delegations << [owner, method_name, target, callee]
      end

      ShapeReader.forward_shapes(node.body, parameters).each do |parameter, callee|
        @forwards << ForwardMethod.new(owner: owner, method: method_name, parameter: parameter, callee: callee)
      end
    end

    def collect_class_body_call(node)
      case node.name
      when :extend
        return unless NodeReading.bare_or_self?(node) && node.arguments

        node.arguments.arguments.each do |argument|
          @names.record_extend(@names.current_scope, argument)
        end
      else
        return unless NodeReading.bare_or_self?(node)

        if node.block.is_a?(Prism::BlockNode)
          @stored_calls << StoredCall.new(owner: nil, subject: @names.current_scope, method: node.name.to_s,
                                          block: node.block, source: @source)
        elsif node.arguments
          # One apply per argument. `apply(A, B)` asks for A's block AND B's,
          # which is what a `*modules` forward means at runtime — each gets its
          # own candidate, and each resolves (or declines) on its own evidence.
          # Only single-argument calls used to be read at all, so the plural
          # form resolved nothing (felixefelip/rbs_infer#253).
          node.arguments.arguments.each do |argument|
            @apply_calls << ApplyCall.new(owner: nil, subject: @names.current_scope, method: node.name.to_s, argument: argument)
          end
        end
      end
    end

    # Method shapes declared OUTSIDE this file.
    #
    # The call sites stay this file's — the expander rewrites this source and
    # nothing else, so an `apply` written elsewhere would name a target this
    # rewrite cannot reach — but the DSL those calls arrive at may be declared
    # anywhere. For a reopening of a core class it always is: `Module#include`
    # is how `ActiveSupport::Concern` writes the applier, and no file that USES
    # a concern declares it (felixefelip/rbs_infer#256).
    #
    # `Corpus` decides which files those are and in what order; what to do with
    # what it finds is this method, and it is two things — keep the shapes, and
    # record the names as declared, since a name the chain reached is one this
    # file can now answer for.
    def absorb_external_shapes
      reached = Corpus.new(@sources).reach(external_lookups) do |entry|
        shapes = self.class.new(entry.source, sources: RbsInfer::Project::ConstantSources::NONE)
                     .collect_shapes(entry.result.value)
        # Read HERE, where one collector may read another's: the walk is handed
        # what to queue next rather than reaching for a protected reader.
        [shapes, shapes.external_lookups]
      end

      reached.shapes.each { |shapes| absorb(shapes) }
      @names.declare_all(reached.names)
    end

    # Every constant this file NAMES but may not declare, as
    # `[naming scope, node]`.
    #
    # `extend`'s and a superclass's, which say where the applier's own methods
    # come from — and the APPLY ARGUMENT, which says where the block does.
    # `include IncludedHook::Shared` names the module holding the block, and it
    # is the only mention of it in the file: without asking about it the module
    # is not in `@declarations`, so `resolve_constant` answers nil for the very
    # argument being applied and the chain ends before it starts. That is the
    # ordinary shape of a concern — declared in its own file, used from
    # another — rather than an exotic one (felixefelip/rbs_infer#265).
    def external_constants
      @names.named_constants + @apply_calls.map { |apply| [apply.subject, apply.argument] }
    end

    # Every constant this file names but does not declare, each as the ORDERED
    # list of names Ruby would try for it — innermost enclosing scope first,
    # top level last.
    #
    # A name is not a constant. `include Fields` inside `class Filter` reaches
    # `Filter::Fields` in one project and a top-level `Fields` in another, and
    # the difference is which one is declared — the same question
    # `resolve_constant` already asks of this file's own declarations, asked of
    # the project instead. Reading the name as written, a relatively-included
    # concern named a constant nothing declares: `parsed_for` opened no file, so
    # the concern's shapes were never absorbed and its `included do` stayed on
    # the concern (felixefelip/rbs_infer#289).
    #
    # Candidates, not an answer, because only `parsed_for` can decide between
    # them and this method is also read by a collector that HAS no project (see
    # `absorb`). The core reopens carry a one-element list for the same reason
    # they carry a name: `Module` means `Module`, wherever it is written.
    def external_lookups
      lookups = CORE_REOPENS.map { |name| [name] }

      external_constants.each do |subject, raw_constant|
        next if @names.resolve(raw_constant, subject)

        name = RbsInfer::Analyzer.extract_constant_path(raw_constant)
        lookups << Corpus.lookup_candidates(name, subject) if name
      end

      lookups.uniq
    end

    # Read by the collector ABSORBING this one, to follow the chain past it: a
    # concern names the module holding its DSL, and that module's file is one
    # the host never mentions. Protected rather than listed with the readers
    # above, because the method is written below among the private ones and a
    # reader there would only be shadowed by it.
    protected :external_lookups

    def absorb(shapes)
      @storages.concat(shapes.storages)
      @readers.concat(shapes.readers)
      @replay_methods.concat(shapes.replay_methods)
      @inward_replays.concat(shapes.inward_replays)
      @deferrals.concat(shapes.deferrals)
      @slot_inits.concat(shapes.slot_inits)
      # The other file's CALL SITES, for one question only: which modules it
      # registered on a waypoint. `Post::Commentable` includes the shared
      # concern in its own file and `Post` includes `Post::Commentable` in
      # another, so the hop and the class that closes it are never written
      # together — and reading only this file's, the host saw a waypoint holding
      # nothing (felixefelip/rbs_infer#300). They are kept out of `@apply_calls`
      # because nothing may EMIT from them: this pass rewrites one source, and a
      # call site elsewhere names a target it cannot reopen.
      @foreign_applies.concat(shapes.apply_calls)
      @forwards.concat(shapes.forwards)
      @resolved_delegations.concat(shapes.resolved_delegations)
      @resolved_inward_extends.concat(shapes.resolved_inward_extends)
      @resolved_own_replays.concat(shapes.resolved_own_replays)
      # And what that file DECLARES, which no other shape needs: a `const_get`
      # is resolved under the module being included, and whether that module
      # holds the constant is a fact about the concern's own file.
      @names.absorb(kinds: shapes.declaration_kinds, providers: shapes.providers)
      # The two that carry a BLOCK. A DSL is routinely written in one file and
      # used from another — a concern in `app/models/concerns` and the class
      # that includes it — so the block and the `include` naming its target are
      # in different files, and reading only this one resolved neither half
      # (felixefelip/rbs_infer#265). They travel with the source they were
      # sliced from, which is what makes moving a foreign block safe.
      @literal_replays.concat(shapes.literal_replays)
      @stored_calls.concat(shapes.stored_calls)
    end

    def resolve_replays
      # `attr_reader :body` is collected from its lexical owner after all
      # declarations are known, so a relative `extend Builder` can resolve.
      collect_readers_from_source

      @deferrals.concat(resolve_deferrals)
      # Built once the delegations below are resolved, since `keeper` reads them.
      @graph = DslGraph.new(replay_methods: @replay_methods, readers: @readers,
                            inward_replays: @inward_replays, literal_replays: @literal_replays,
                            forwards: @forwards, delegations: @resolved_delegations,
                            storages: @storages)

      providers = @names.providers
      @resolved_delegations.concat(resolve_delegations)
      @resolved_inward_extends.concat(resolve_inward_extends)
      @resolved_own_replays.concat(resolve_own_replays)

      # BEFORE anything is emitted, and over every call site the project wrote
      # rather than only this file's: a waypoint's registrations decide whether
      # the applications below land here or pass through, and the two are
      # routinely in different files.
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
      resolved = @stored_calls.filter_map { |stored| resolve_own_block(stored, providers) }
                              .select { |replay| replay.source.equal?(@source) }

      @extensions = @apply_calls.flat_map { |apply| resolve_extensions(apply, providers) }.uniq

      resolved += @apply_calls.flat_map { |apply| resolve_apply(apply, providers) }

      # Two apply calls naming the same source in the same class body are one
      # replay written twice, not two — the block relocates to that class once.
      # Keyed on the block's own SOURCE as well as its offset, since two files
      # hold blocks at the same offset all the time and a location says nothing
      # about which file it indexes.
      resolved.uniq { |replay| [replay.target, replay.singleton, replay.source, replay.block.location.start_offset] }
    end

    # The block a DSL call runs where it stands, or nil when the file does not
    # decide it.
    #
    # The same call `resolve_apply`'s chain treats as STORAGE, asked the other
    # question: not "which earlier block does this apply", but "does the method
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
        replays = @resolved_own_replays.select { |own| own.owner == provider && own.method == stored.method }
        next unless replays.size == 1

        replay_where_written(stored, replays.first, providers)
      end.uniq

      # Two providers answering one call with two different targets is one
      # runtime dispatch this pass cannot pick a winner for — the same count
      # `resolve_apply` declines on.
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

      @resolved_inward_extends.any? do |extension|
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
    def resolve_apply(apply, providers)
      source_subject = @names.resolve(apply.argument, apply.subject)
      return [] unless source_subject

      resolve_application(apply.subject, apply.method, source_subject, providers, Set.new)
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
    def resolve_application(subject, method, source_subject, providers, seen)
      return [] unless seen.add?([subject, source_subject])

      deferral = deferral_for(subject, method, source_subject, providers)
      return [] if deferral && holds_slot?(subject, source_subject, deferral.slot, providers)

      replays = [direct_replay(subject, method, source_subject, providers)].compact
      return replays unless deferral

      replays + @deferred_registry[source_subject].flat_map do |held|
        resolve_application(subject, deferral.recall, held, providers, seen)
      end
    end

    # Which modules each waypoint is holding, read off every call site the
    # project writes.
    #
    # A registration is a fact about the module that made it, not about the file
    # asking — so this walks the absorbed call sites too, and the entries it
    # writes are read back by `resolve_application` in whatever file finally
    # closes the hop.
    def register_deferrals(providers)
      (@apply_calls + @foreign_applies).each do |apply|
        source_subject = @names.resolve(apply.argument, apply.subject)
        next unless source_subject

        deferral = deferral_for(apply.subject, apply.method, source_subject, providers)
        next unless deferral && holds_slot?(apply.subject, source_subject, deferral.slot, providers)

        registered = @deferred_registry[apply.subject]
        registered << source_subject unless registered.include?(source_subject)
      end
    end

    # The deferral the DSL behind one application writes, or nil when it always
    # replays where it stands. Same two-sided walk `direct_replay` makes — the
    # applier answers for the subject, the keeper for the module — because the
    # method that defers is the one the module's own provider supplies.
    def deferral_for(subject, method, source_subject, providers)
      appliers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      sources = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      found = appliers.product(sources).flat_map do |applier, source_provider|
        @graph.keepers_for(applier, method, source_provider).flat_map do |keeper_owner, keeper_method|
          @deferrals.select { |deferral| deferral.owner == keeper_owner && deferral.method == keeper_method }
        end
      end.uniq

      found.first if found.size == 1
    end

    # Whether `subject` holds the slot the DSL branches on — which is the branch
    # taken, evaluated per call site.
    #
    # Not by reading the predicate. What the predicate asks (`does base have
    # @_dependencies`) is answered by the method that PUTS it there: a `SlotInit`
    # in the DSL's own chain says the objects handed to that DSL hold the slot,
    # and `@names.providers` says which those are. So `Post::Commentable`, which
    # extends the concern DSL, holds it and defers; `Post`, which extends
    # nothing, does not and replays. A DSL whose slot nothing in the corpus
    # initialises holds for nobody, which is the same "nothing to say" every
    # other lookup here answers with.
    def holds_slot?(subject, source_subject, slot, providers)
      providers.any? do |owner, subjects|
        next false unless subjects.include?(source_subject) && subjects.include?(subject)

        @slot_inits.any? do |init|
          init.ivar == slot && [owner, Declarations.singleton_owner(owner)].include?(init.owner)
        end
      end
    end

    # The one block an application relocates, or nil when the file does not
    # decide it.
    #
    # Two provider questions, not one. The applier is dispatched on the
    # SUBJECT (`banana` arrives in `Bar`'s body) and the callee it forwards
    # to on the ARGUMENT (`mod.send(:bananed, self)` runs on `Baz`), so the
    # two are answered by whatever supplies each — which need not be the
    # same module. Requiring one provider for both is what `ActiveSupport`'s
    # own shape breaks: `Module#include` reaches for `append_features`, a
    # method of the concern (felixefelip/rbs_infer#256).
    def direct_replay(subject, method, source_subject, providers)
      appliers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      sources = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      candidates = appliers.product(sources).filter_map do |applier, source_provider|
        replay_for(subject, method, applier, source_provider, source_subject)
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

    # The `extend`s one apply call site puts on its target.
    #
    # The same walk `resolve_apply` makes, over the same providers, and separate
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
    def resolve_extensions(apply, providers)
      source_subject = @names.resolve(apply.argument, apply.subject)
      return [] unless source_subject

      extensions_for(apply.subject, apply.method, source_subject, providers, Set.new)
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
      return [] if deferral && holds_slot?(subject, source_subject, deferral.slot, providers)

      direct = direct_extensions(subject, method, source_subject, providers)
      return direct unless deferral

      direct + @deferred_registry[source_subject].flat_map do |held|
        extensions_for(subject, deferral.recall, held, providers, seen)
      end
    end

    def direct_extensions(subject, method, source_subject, providers)
      kind = @names.own_kind(subject)
      return [] unless kind

      appliers = providers.select { |_, subjects| subjects.include?(subject) }.keys
      sources = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      answers = appliers.product(sources).filter_map do |applier, source_provider|
        names = extension_names(applier, method, source_provider, source_subject)
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
      @forwards.flat_map do |forward|
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
        @resolved_inward_extends.filter_map do |extension|
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

    # The collected `extend`s with their written constants resolved, against the
    # declarations of the file they were WRITTEN in — which is the only place
    # that name can be looked up, and the same reason `resolve_delegations` runs
    # here and again in `collect_shapes`. A dynamic name has nothing to resolve
    # yet and passes through; it is decided per call site, in `extension_name`.
    def resolve_inward_extends
      @inward_extends.filter_map do |owner, method, parameter, name, dynamic, creates|
        if dynamic
          InwardExtend.new(owner: owner, method: method, parameter: parameter, name: name, dynamic: true,
                           creates: creates)
        else
          resolved = @names.resolve(name, Declarations.lexical_context(owner))
          next unless resolved && @names.own_kind(resolved) == "module"

          InwardExtend.new(owner: owner, method: method, parameter: parameter, name: resolved, dynamic: false,
                           creates: creates)
        end
      end
    end

    # The collected own-block replays with their written constants resolved,
    # against the declarations of the file they were WRITTEN in — the same
    # two-place resolution `resolve_inward_extends` does, and for the same
    # reason. A target that is our own `self`, or a name fetched as data, has
    # nothing to resolve here: both are decided per call site.
    def resolve_own_replays
      @own_replays.filter_map do |owner, method, name, dynamic, creates, singleton|
        if name.nil? || dynamic
          OwnBlockReplay.new(owner: owner, method: method, name: name, dynamic: dynamic, creates: creates,
                             singleton: singleton)
        else
          resolved = @names.resolve(name, Declarations.lexical_context(owner))
          next unless resolved

          OwnBlockReplay.new(owner: owner, method: method, name: resolved, dynamic: false, creates: creates,
                             singleton: singleton)
        end
      end
    end

    # The collected method bodies read as deferrals, once the readers are in.
    def resolve_deferrals
      reader = DeferralReader.new(@readers)

      @deferral_shapes.filter_map do |owner, method, body, parameters|
        shape = reader.shape(body, parameters)
        next unless shape

        parameter, slot, recall = shape
        Deferral.new(owner: owner, method: method, parameter: parameter, slot: slot, recall: recall)
      end
    end

    def replay_for(subject, method, applier, source_provider, source_subject)
      # Both directions answer with the SLOT — and with the object that owns
      # it, which is not always the provider: a delegating DSL method keeps
      # the block on something it holds. From there the chain is one and the
      # same: whoever fills that slot is the storage method, and the call the
      # source wrote under that name holds the block. Asking both and
      # requiring a single answer is what keeps a file that somehow reads as
      # both from being resolved by declaration order.
      slots = [@graph.outward_slot(applier, method),
               @graph.inward_slot(applier, method, source_provider)].compact.uniq
      # And the third way to reach a block: not through a slot at all,
      # because the replaying method wrote it in place. Counted together
      # with the slots, so a file reading as both still declines.
      literals = @graph.literal_replays_for(applier, method, source_provider)
      return nil unless slots.size + literals.size == 1

      kind = @names.own_kind(subject)
      return nil unless kind

      if (literal = literals.first)
        return Replay.new(target: subject, block: literal.block, kind: kind,
                          call: literal.call, scope: literal.scope, in_method: literal.method,
                          source: literal.source, singleton: literal.singleton, extended: false)
      end

      storage_owner, ivar, singleton = slots.first
      # The SOURCE's provider, not the applier's: the name being looked up
      # is the one the source wrote in its own body.
      storage_method = @graph.storage_method_for(source_provider, storage_owner, ivar)
      return nil unless storage_method

      blocks = @stored_calls.select { |stored| stored.subject == source_subject && stored.method == storage_method }
      return nil unless blocks.size == 1

      Replay.new(target: subject, block: blocks.first.block, kind: kind,
                 call: storage_method, scope: blocks.first.subject, in_method: nil,
                 source: blocks.first.source, singleton: singleton, extended: false)
    end

    def resolve_delegations
      @delegations.filter_map do |owner, method, raw_target, callee|
        target = @names.resolve(raw_target, owner)
        Delegation.new(owner: owner, method: method, target: target, callee: callee) if target
      end
    end

    # `attr_reader` is a normal call in a class/module body; collect it in a
    # second short lexical walk because declarations must be known before a
    # relative constant can be resolved. Keeping reader recognition explicit
    # is what prevents an arbitrary method named `body` from being treated as
    # an ivar accessor.
    def collect_readers_from_source
      parsed = Prism.parse(@source)
      reader_collector = ReaderCollector.new
      parsed.value.accept(reader_collector)
      @readers.concat(reader_collector.readers)
    end
  end
end
