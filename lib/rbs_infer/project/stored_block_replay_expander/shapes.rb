# frozen_string_literal: true

module RbsInfer::Project::StoredBlockReplayExpander
  # What `Collector` collects, as data.
  #
  # One `Data.define` per shape a file can be read as writing, and the reason
  # each carries the fields it does is written on it — those comments are the
  # record of what a field turned out to be load-bearing FOR, and most of them
  # were added when a missing one produced a wrong answer somewhere far away
  # (a `singleton` bit that decided `def age` against `def self.age`, a `source`
  # that decided which file a block's offsets index).
  #
  # Held apart from the collector for the plainest of reasons: they are
  # declarations, not behaviour.
  #
  # Included rather than referenced, so `Storage` keeps meaning `Storage` in
  # every method that builds one: a constant reached through an ancestor
  # resolves exactly as one written in the class did.
  module Shapes
    # What a class body and a module body can call with no receiver, beyond
    # anything this file says: `self` there is an instance of `Class` or of
    # `Module`, so the callable methods are those two chains' instance methods.
    #
    # Read off Ruby rather than listed. `%w[Module Class]` was the same claim
    # asserted, and it was both arbitrary and short: `class Object; def banana`
    # makes `banana` callable in every class body just as surely, and the pair
    # missed it.
    #
    # The SUPERCLASS chain, not `ancestors`. Both derive, but `ancestors` reads
    # the live process rather than the language: measured, `Class.ancestors`
    # answers `PP::ObjectMixin` and `JSON::GeneratorMethods` here, because `pp`
    # and `json` inject into `Object` and rbs_infer loads them. Which gems the
    # ANALYZER happens to require is no fact about the analyzed project, and it
    # would make this list differ between environments. A superclass chain
    # cannot be injected into, so it says the same thing everywhere.
    #
    # That leaves out `Kernel`, and knowingly: it is a module, so nothing at
    # runtime distinguishes it from the two above. A `module Kernel` reopening
    # holding a supplying module is not a shape worth reading the live process for.
    #
    # Deliberately NOT the ancestors RBS knows, either. That query answers
    # (measured: `singleton(::Example39::Bar)` + `banana` -> `::Module`), but
    # only once `sig/` already holds a signature for the reopening — which
    # rbs_infer generated. A pre-parse source rewrite reading its own previous
    # output is the circularity of felixefelip/rbs_infer#156: on a cold
    # checkout the same query answers `nil` and nothing expands. This pass
    # keeps syntax, not generated types.
    def self.self_chain(klass)
      chain = []
      while klass
        chain << klass.name
        klass = klass.superclass
      end
      chain.freeze
    end

    CORE_SELF_CHAINS = { "class" => self_chain(Class), "module" => self_chain(Module) }.freeze

    CORE_REOPENS = CORE_SELF_CHAINS.values.flatten.uniq.freeze

    Storage = Data.define(:owner, :method, :ivar)

    # `singleton` — carried by all three replay shapes below — is WHICH method
    # table the block's `def`s land in. `target.class_eval` puts them in the
    # target's own, reached by its instances; `target.singleton_class.class_eval`
    # puts them in the target's singleton, reached by the class object itself.
    # That is the one difference between a DSL spelling `included do` and one
    # spelling `class_methods do`, and it is a difference in the emitted RBS
    # (`def age` against `def self.age`), so it has to travel with the replay
    # rather than be re-derived from the call at rewrite time
    # (felixefelip/rbs_infer#267).
    ReplayMethod = Data.define(:owner, :method, :parameter, :reader, :singleton)
    # `source` is the file the block was written in, and it travels with the
    # block because a `Prism::Location` is only offsets — meaningless without
    # the string they index. The rewrite slices it to move the body, and the
    # block may come from another file (see `absorb`).
    StoredCall = Data.define(:owner, :subject, :method, :block, :source)
    ModuleCall = Data.define(:owner, :subject, :method, :argument)

    # The same replay written from the other end — `base.class_eval(&@block)`,
    # where `self` is the module that KEPT the block and the target arrives as a
    # parameter. `ReplayMethod` is the mirror: there `self` is the target and the
    # source arrives as the parameter (felixefelip/rbs_infer#247).
    #
    # It reads the ivar directly because there is nothing to read it through:
    # a reader exists to let ANOTHER object at the slot, and in this direction
    # the replaying method is already inside the object that owns it. So the ivar
    # is named here where `ReplayMethod` names a reader — the slot is the join
    # either way, and `attr_reader` was only ever one spelling of reaching it.
    InwardReplay = Data.define(:owner, :method, :parameter, :ivar, :singleton)

    # A DSL that hands ITSELF to the target instead of replaying on it, read off
    # the one conditional that writes both outcomes (felixefelip/rbs_infer#300).
    #
    # `ActiveSupport::Concern#append_features` is the shape, and its transcribed
    # source is the whole evidence:
    #
    #     if base.instance_variable_defined?(:@_dependencies)
    #       base.instance_variable_get(:@_dependencies) << self   # registers
    #       false
    #     else
    #       @_dependencies.each { |dep| base.include(dep) }       # drains
    #       base.class_eval(&@_included_block)                    # replays
    #     end
    #
    # Three nodes on two mutually exclusive branches, and this reads all three.
    # `slot` is what joins them: `self` goes INTO the target's `@slot` on one
    # branch, and on the other the module's OWN `@slot` is emptied back onto the
    # target. So a module registered on a waypoint is not lost — it is
    # re-applied to whatever class finally arrives, which is why the block lands
    # on the host and never on the waypoint. `recall` is the message the drain
    # re-sends (`include`), and the re-application is resolved AS that call
    # site, through the same chain any other one takes.
    #
    # Deliberately NOT a match on `<< self`: that was the shortcut this replaces
    # (felixefelip/rbs_infer#299), which read `push(self)` as no deferral at all
    # and would have read a DSL that registered AND replayed on one branch as
    # one. What decides here is the register/replay pair being on OPPOSITE
    # branches with the drain rejoining them — a statement about the code's
    # structure rather than about one gem's spelling.
    Deferral = Data.define(:owner, :method, :parameter, :slot, :recall)

    # `<parameter>.instance_variable_set(:@x, …)` — a method that puts a slot on
    # the object it is handed.
    #
    # It is what makes the branch above DECIDABLE per call site. The predicate
    # asks whether the target holds the slot, and the answer is not in the
    # predicate: it is here, in the method that puts it there. Whoever the DSL
    # was handed to holds it, and `dsl_providers` already says who that is — so
    # `Post::Commentable`, which extends the concern DSL, holds `@_dependencies`
    # and `Post`, which only includes a concern, does not.
    SlotInit = Data.define(:owner, :method, :parameter, :ivar)

    # The same replay again, with the block written where it is run instead of
    # kept for later: `def self.included(base) = base.class_eval do … end`, which
    # is what Ruby's own `included` hook looks like when nobody has wrapped it in
    # a DSL (felixefelip/rbs_infer#260).
    #
    # No storage, so nothing to look up — the block is right there in the
    # replaying method, and only the target is unknown. `call` and `scope` name
    # the call the block belongs to (`class_eval`, in the module holding the
    # hook) rather than the storage call and the module that wrote it, since
    # there is no storage call here; both feed the `blocks:` sidecar the same way.
    # `source` for the same reason `StoredCall` carries one.
    LiteralReplay = Data.define(:owner, :method, :scope, :call, :block, :source, :singleton)

    # `def keep(&block) = <target>.module_eval(&block)` — the DSL that runs the
    # block it was just handed, with no slot in between. Both other outward
    # shapes reach their block through storage (`keep` fills an ivar, `apply`
    # reads it back through a reader), so a DSL that evaluates immediately had
    # no shape at all — not even the plainest one, `class_eval(&block)`
    # (felixefelip/rbs_infer#268).
    #
    # `name` is what it runs ON, and nil is an answer: the DSL's own `self`,
    # which is the subject that called it. A CONSTANT is the other answer, and
    # it carries the same syntax/data distinction every constant does — written,
    # it means what it means where the DSL is written; fetched with `const_get`,
    # it is looked up under the caller's `self`, which is the subject.
    #
    # `singleton` is the same bit it is on every other replay: `class_eval` puts
    # the block's `def`s in the subject's own table, `singleton_class.class_eval`
    # in the class object's.
    OwnBlockReplay = Data.define(:owner, :method, :name, :dynamic, :creates, :singleton)

    # `base.extend(<module>)` — the other thing a hook does to the object it is
    # handed, and the one that carries no block at all: the target's SINGLETON
    # gains a module that already exists, rather than a block's `def`s being
    # moved onto it. It is the half of `ActiveSupport::Concern` that turns
    # `class_methods do` into the host's class methods, and the transcription of
    # `append_features` has been writing it since felixefelip/rbs_infer#262 with
    # nothing reading it (felixefelip/rbs_infer#268).
    #
    # `name` is the module, and `dynamic` says which question is left to answer
    # about it. A constant written as SYNTAX is resolved where it was written —
    # its lexical scope is the file's, and nothing about the target changes it.
    # A name fetched as DATA (`const_get(:ClassMethods)`) is resolved against
    # whatever `self` is when the hook runs, which is the module being included
    # and so is only known at the call site.
    InwardExtend = Data.define(:owner, :method, :parameter, :name, :dynamic, :creates)

    # One `extend` a module call puts on its target, resolved: the class or
    # module to reopen, and the module its singleton gains.
    Extension = Data.define(:target, :kind, :name)

    # `def bazinga(mod) = mod.bazingado(self)` — the hop from the method a target
    # NAMES to the method that replays. The inward direction needs it: the replay
    # runs on the source with the target passed in, so the target's own body
    # cannot be the one calling it.
    #
    # `singleton` is WHICH method table the callee is found in, and it travels
    # with the forward for the same reason it travels with the three replay
    # shapes: `mod.bazingado(self)` and `mod.singleton_class.bazingado(self)` are
    # two different methods, and re-deriving which one from the call site is not
    # possible once the shape has been collected. `Module#extend_object` is the
    # second form (felixefelip/rbs_infer#311).
    ForwardMethod = Data.define(:owner, :method, :parameter, :callee, :singleton)

    # `def bazingado(base = nil, &block)` whose body is
    # `(@holder ||= Holder.new).bazingado(base, &block)` — a method that keeps
    # nothing itself and hands the whole call, block included, to an object it
    # holds. The block then lives in `Holder`, which nothing extends, so without
    # this hop the storage and the replay sit in an owner no subject can reach
    # (felixefelip/rbs_infer#257).
    #
    # `target` is the class the holder is built from, resolved in
    # `resolve_replays` like `extend`'s and a superclass's: a constructor written
    # relatively may name a class the walk has not reached yet.
    Delegation = Data.define(:owner, :method, :target, :callee)
  end
end
