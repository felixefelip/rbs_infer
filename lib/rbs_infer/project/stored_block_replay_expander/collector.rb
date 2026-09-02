# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../ast/constant_reference"
require_relative "../../inference/send_call"
require_relative "../constant_sources"

module RbsInfer::Project::StoredBlockReplayExpander
  # Collects declarations and class-body calls in one lexical pass. It keeps
  # syntax, not guessed types: resolving `Foo` in `extend Foo` and `Baz` in
  # `apply(Baz)` uses the declarations that are actually present in the file.
  class Collector < Prism::Visitor
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
    # holding a DSL applier is not a shape worth reading the live process for.
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

    # What `singleton_class_of` answers for a call written on no receiver at
    # all. A `Symbol` rather than a fabricated node: nothing reads it back as
    # syntax, only compares it.
    IMPLICIT_RECEIVER = :self

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
    ApplyCall = Data.define(:owner, :subject, :method, :argument)

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

    # One `extend` an apply call site puts on its target, resolved: the class or
    # module to reopen, and the module its singleton gains.
    Extension = Data.define(:target, :kind, :name)

    # `def bazinga(mod) = mod.bazingado(self)` — the hop from the method a target
    # NAMES to the method that replays. The inward direction needs it: the replay
    # runs on the source with the target passed in, so the target's own body
    # cannot be the one calling it.
    ForwardMethod = Data.define(:owner, :method, :parameter, :callee)

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

    # `sources` is required, and `ConstantSources::NONE` is the way to say "no
    # project here". A DSL whose methods are declared in another file resolves
    # to nothing without it and reports nothing about why, which is the
    # silent-wrong case (docs/engineering/required-threaded-deps.md).
    def initialize(source, sources:)
      @source = source
      @sources = sources
      @scope = []
      @method_depth = 0
      @declarations = Set.new
      @declaration_kinds = {}
      @extends = []
      @superclasses = []
      @storages = []
      @readers = []
      @replay_methods = []
      @inward_replays = []
      # Raw like `@delegations`, and resolved the same way: a constant written
      # in a hook's body may name a module declared later in the file.
      @inward_extends = []
      @resolved_inward_extends = []
      # Raw and resolved like the extends above, and for the same reason: the
      # constant a DSL names may be declared further down its own file.
      @own_replays = []
      @resolved_own_replays = []
      # What the files this one absorbs shapes from DECLARE. Read for one
      # question only — is the module a `const_get` names actually there — which
      # is why it is kept apart from `@declaration_kinds` rather than merged
      # into it: every other reader of that hash is asking about a declaration
      # THIS file makes, and widening it would answer them about somebody
      # else's.
      @absorbed_kinds = {}
      # Who can call whose DSL, as the files this one absorbs write it. Kept
      # apart from the table this file builds for the same reason
      # `@absorbed_kinds` is: one is a fact about this source, the other about
      # somebody else's, and only the merge answers "who supplies this method".
      @absorbed_providers = Hash.new { |hash, key| hash[key] = Set.new }
      # Namespaces this file's own DSL calls BRING INTO EXISTENCE —
      # `const_set(:X, Module.new)` under the subject that called it. Filled
      # while the replays resolve and read back by everything that asks whether
      # a name is declared: the module is not in any file's text, and the
      # reopening this pass emits for it is what declares it.
      @created_kinds = {}
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
      @resolved_delegations = resolve_delegations
      @resolved_inward_extends = resolve_inward_extends
      @resolved_own_replays = resolve_own_replays
      # Who can call whose DSL, as THIS file writes it. A shape is only half of
      # what another file needs: `extend ActiveSupport::Concern` is written in
      # the concern, and without it a host holding the concern's shapes still
      # cannot say which owner supplies them.
      @providers = dsl_providers
      self
    end

    # The `extend`s the apply calls in this file put on their targets. Populated
    # by `collect`, alongside the replays it answers with: both are what a call
    # site here does to a class here, read off the same resolution.
    attr_reader :extensions

    protected

    attr_reader :storages, :readers, :replay_methods, :inward_replays, :forwards, :resolved_delegations,
                :literal_replays, :stored_calls, :resolved_inward_extends, :declaration_kinds,
                :resolved_own_replays, :providers

    public

    def visit_class_node(node)
      with_scope(node) { super }
    end

    def visit_module_node(node)
      with_scope(node) { super }
    end

    def visit_def_node(node)
      collect_method_shape(node) if current_scope
      @method_depth += 1
      super
    ensure
      @method_depth -= 1
    end

    def visit_call_node(node)
      collect_class_body_call(node) if current_scope && @method_depth.zero?
      super
    end

    private

    def with_scope(node)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return yield unless name

      qualified = qualify(name)
      @declarations << qualified
      @declaration_kinds[qualified] = node.is_a?(Prism::ModuleNode) ? "module" : "class"
      # Kept raw and resolved in `resolve_replays`, exactly like `extend`: a
      # superclass written relatively may name a class the walk has not reached
      # yet, and only the finished declaration set can say which one it is.
      @superclasses << [qualified, node.superclass] if node.is_a?(Prism::ClassNode) && node.superclass
      @scope << qualified
      yield
    ensure
      @scope.pop if @scope.last == qualified
    end

    def current_scope
      @scope.last
    end

    def qualify(name)
      name = name.to_s.sub(/\A::/, "")
      return name if name.include?("::")

      parent = @scope.last
      parent ? "#{parent}::#{name}" : name
    end

    def resolve_constant(node, context)
      name = RbsInfer::Analyzer.extract_constant_path(node)
      return nil unless name

      # `::Mentions` names the top level and NOTHING ELSE, so it is answered
      # here — before the prefix comes off, which is what the guard that used to
      # sit below the strip could not do: nothing starts with `::` by then, so
      # it never fired and an absolute name fell through to the nesting walk.
      # Written inside `Card::Mentions`, `include ::Mentions` resolved to the
      # enclosing `Card::Mentions` itself. The module was then recorded as a
      # host of its own `included do`, and Steep — which checks a block once per
      # `@implements` name — checked the body a second time against a `self`
      # that has none of the host's methods (felixefelip/rbs_infer#299).
      #
      # Still gated on `@declarations`, like every other answer here. A non-nil
      # return means "this file declares it", which `external_lookups` reads as
      # "nothing to absorb"; answering unconditionally told it that about
      # `include ::Storage::Tracked` in `board.rb`, the concern's file was never
      # opened, and `Board` dropped out of the very list this is fixing.
      if name.start_with?("::")
        top_level = name.delete_prefix("::")
        return @declarations.include?(top_level) ? top_level : nil
      end

      return name if name.include?("::") && @declarations.include?(name)

      prefixes = context.to_s.split("::")
      prefixes.length.downto(1) do |length|
        candidate = "#{prefixes.take(length).join("::")}::#{name}"
        return candidate if @declarations.include?(candidate)
      end
      @declarations.include?(name) ? name : nil
    end

    def collect_method_shape(node)
      owner = shape_owner(node)
      return unless owner

      params = node.parameters
      block_name = params&.block&.name&.to_s
      method_name = node.name.to_s

      if block_name && (ivar = stored_block_ivar(node.body, block_name))
        @storages << Storage.new(owner: owner, method: method_name, ivar: ivar)
      end

      if (replay = replay_shape(node.body))
        parameter, reader, singleton = replay
        @replay_methods << ReplayMethod.new(owner: owner, method: method_name, parameter: parameter, reader: reader,
                                            singleton: singleton)
      end

      parameters = handed_names(node.body, parameter_names(params))

      if (inward = inward_replay_shape(node.body, parameters))
        parameter, ivar, singleton = inward
        @inward_replays << InwardReplay.new(owner: owner, method: method_name, parameter: parameter, ivar: ivar,
                                            singleton: singleton)
      end

      if (own = own_block_replay_shape(node.body, block_name))
        name, dynamic, creates, singleton = own
        @own_replays << [owner, method_name, name, dynamic, creates, singleton]
      end

      inward_extend_shapes(node.body, parameters).each do |parameter, name, dynamic, creates|
        @inward_extends << [owner, method_name, parameter, name, dynamic, creates]
      end

      if (literal = literal_replay_shape(node.body, parameters))
        call, block, singleton = literal
        @literal_replays << LiteralReplay.new(owner: owner, method: method_name, scope: current_scope,
                                              call: call, block: block, source: @source, singleton: singleton)
      end

      if (delegation = delegation_shape(node))
        target, callee = delegation
        @delegations << [owner, method_name, target, callee]
      end

      forward_shapes(node.body, parameters).each do |parameter, callee|
        @forwards << ForwardMethod.new(owner: owner, method: method_name, parameter: parameter, callee: callee)
      end
    end

    # Which method table a `def` puts the method in, in the terms
    # `dsl_providers` keys on. `def keep` goes in the module's own, reached by
    # whoever `extend`s it; `def self.keep` goes in the SINGLETON's, reached by
    # the subject in its own body and by its subclasses. Both used to be
    # recorded under the lexical scope, which happened to work only because no
    # shape yet needed telling the two apart — `IncludedHook::Hookable` does,
    # since its `def self.included` is reached by nothing but Hookable itself
    # (felixefelip/rbs_infer#260).
    #
    # `def SomeOther.foo` and `def obj.foo` answer nothing: which object that
    # names is not a question this pass asks, so the method is not collected at
    # all rather than filed under the wrong owner.
    def shape_owner(node)
      return current_scope unless node.receiver
      return singleton_owner(current_scope) if node.receiver.is_a?(Prism::SelfNode)

      nil
    end

    # No file can declare a constant by this name, so a singleton owner cannot
    # collide with a real one.
    def singleton_owner(name)
      "singleton(#{name})"
    end

    # The names a `def` or a block binds its arguments to. One reader for both:
    # `BlockParametersNode#parameters` IS a `ParametersNode`, so "what does this
    # bind" has one answer regardless of which construct asked.
    #
    # A destructuring target (`|(a, b)|`) is a `MultiTargetNode` and carries no
    # `name`, so it is skipped — the same way a method's would be.
    def parameter_names(params)
      return Set.new unless params.is_a?(Prism::ParametersNode)

      names = params.requireds + params.optionals + params.posts + params.keywords
      names = names.filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
      names << params.rest.name.to_s if params.rest.respond_to?(:name) && params.rest&.name
      Set.new(names)
    end

    # Every name the method can be HANDED an object under. A replay against
    # arbitrary state is what this pass declines to guess about, so the shapes
    # below require their receiver to be one of these rather than any local that
    # happens to be in scope.
    #
    # That is the method's parameters, and also the parameters of a block passed
    # to a call ON one of those names. The question the restriction asks is
    # about PROVENANCE — "did this object reach us from the caller, or did we
    # fetch it from somewhere else in the program" — and a value yielded by a
    # method of a handed object answers it the same way the parameter does.
    # `mod` in `modules.reverse_each { |mod| mod.apply(self) }` is as much
    # something we were handed as `modules` is; restricting the receiver to a
    # parameter NAME missed that, so a DSL forwarding to each of several modules
    # resolved nothing (felixefelip/rbs_infer#253).
    #
    # Deliberately NOT a list of iteration methods. Which of the yielded values
    # is "the element" is a question about the receiver's type, which this
    # source-only pass cannot answer and — since the forward's parameter name is
    # never read again, only its callee — does not need to: `Enumerable#inject`
    # yields the memo first and `each_with_index` an index second, so any
    # first-parameter rule would be wrong for one of them while the provenance
    # claim holds for both.
    #
    # Iterated to a fixed point because the relation is transitive — a nested
    # iteration still yields values that came from the caller — terminating
    # because a body binds finitely many names and the set only grows.
    def handed_names(body, parameters)
      names = parameters.dup

      loop do
        grown = false
        nodes(body).each do |node|
          next unless node.is_a?(Prism::CallNode)
          receiver = node.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode) && names.include?(receiver.name.to_s)
          next unless node.block.is_a?(Prism::BlockNode)

          bound = node.block.parameters
          next unless bound.is_a?(Prism::BlockParametersNode)

          parameter_names(bound.parameters).each { |name| grown = true if names.add?(name) }
        end
        break unless grown
      end

      names
    end

    # The call a node stands for, reading `x.send(:foo, a)` as the `x.foo(a)`
    # it is. `Inference::SendCall` is the one place that knows that spelling
    # (felixefelip/rbs_infer#205) and it answers with a real `Prism::CallNode`,
    # so every matcher below reads `name`, `arguments`, `receiver` and `block`
    # off it exactly as it read them off the original.
    #
    # Reading `node.name` directly answered `send` and left the real callee
    # sitting in the argument list, so every shape below missed the spelling —
    # which is the spelling a caller reaches for when the method is private,
    # and the one the generated `Module#include` pseudo-code writes
    # (`mod.send(:included, self)`), for exactly that reason
    # (felixefelip/rbs_infer#255).
    #
    # `desugar` answers nil for a COMPUTED name, and falling back to the node
    # itself is what declines it: the matchers then see `send` with the name
    # still in the argument list and no shape fits. Which method a computed
    # dispatch runs is a runtime answer, and this pass does not guess.
    def dispatched(node)
      RbsInfer::Inference::SendCall.desugar(node) || node
    end

    def stored_block_ivar(body, block_name)
      nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::InstanceVariableWriteNode)
        next unless node.value.is_a?(Prism::LocalVariableReadNode)
        next unless node.value.name.to_s == block_name

        node.name.to_s
      end.uniq.then { |ivars| ivars.first if ivars.size == 1 }
    end

    # `class_eval(&parameter.reader)` / `module_eval(&parameter.reader)`.
    # The receiver is deliberately limited to the method parameter: a replay
    # against arbitrary state needs a type/data-flow answer this source-only
    # pass does not have and must decline rather than guess.
    def replay_shape(body)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::CallNode)
        reader = dispatched(pass.expression)
        next unless (reader.arguments&.arguments || []).empty?
        next unless reader.receiver.is_a?(Prism::LocalVariableReadNode)

        next unless (own = own_receiver(call.receiver))

        [reader.receiver.name.to_s, reader.name.to_s, own == :singleton]
      end.uniq
      shapes.first if shapes.size == 1
    end

    # Which object a replay runs ON, as `[parameter name, singleton?]`, or nil
    # when the receiver is not one this pass will move a block onto.
    #
    # `base.class_eval` and `base.singleton_class.class_eval` are the same
    # relocation asked about two different method tables — `base`'s own, and
    # `base`'s singleton — which is exactly the difference between a DSL
    # spelling `included do` and one spelling `class_methods do`. Reading only
    # the bare parameter made the second one no shape at all, so a `def` a human
    # can see landing on the class object was left in the module that wrote it
    # (felixefelip/rbs_infer#267).
    #
    # The parameter restriction is unchanged and is the whole conservatism here:
    # `singleton_class` is a hop to a DIFFERENT OBJECT, and taking it is only
    # safe because that object is decided by the one we were handed. An
    # arbitrary receiver still declines, singleton or not.
    def replayed_on(receiver, parameters)
      return nil unless receiver

      if (inner = singleton_class_of(receiver))
        return nil unless inner.is_a?(Prism::LocalVariableReadNode) && parameters.include?(inner.name.to_s)

        return [inner.name.to_s, true]
      end

      return nil unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)

      [receiver.name.to_s, false]
    end

    # The same question for the outward direction, where the replay runs on the
    # DSL's own `self` rather than on something handed to it — `:instance` for
    # `class_eval`, `:singleton` for `singleton_class.class_eval`, nil for a
    # receiver that is neither.
    #
    # The receiver used to go unread here, which happened to be harmless while
    # every shape it could take meant the same thing. It no longer does: the
    # rewrite emits a reopening of the SUBJECT — the class whose body wrote the
    # apply call — so a replay written on anything else (`Other.class_eval`) is
    # a block running on a class this pass never resolved, and naming the
    # subject would be an answer about the wrong one.
    def own_receiver(receiver)
      return :instance if receiver.nil? || receiver.is_a?(Prism::SelfNode)
      return :singleton if singleton_class_of(receiver) == IMPLICIT_RECEIVER

      nil
    end

    # The receiver of a `singleton_class` call — the node it is written on,
    # `IMPLICIT_RECEIVER` when it is written on none, or nil when the node is
    # not a `singleton_class` call at all. Three answers rather than two,
    # because "no receiver" is a receiver here: it names the DSL's own `self`.
    #
    # No arguments, because `singleton_class` takes none: a same-named method
    # that does is somebody else's, and it says nothing about a method table.
    def singleton_class_of(node)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      return nil unless call.name == :singleton_class
      return nil unless (call.arguments&.arguments || []).empty?

      receiver = call.receiver
      return IMPLICIT_RECEIVER if receiver.nil? || receiver.is_a?(Prism::SelfNode)

      receiver
    end

    # `<parameter>.class_eval(&@ivar)` — the target is the parameter and the
    # block is the method's own state. Same conservatism as `replay_shape` and
    # for the same reason, only about the other half: there the RECEIVER is
    # `self` and the parameter must be the one carrying the block; here the
    # parameter is the receiver and the block must come off `self`.
    #
    # `if @ivar` guards and `unless base.nil?` branches are irrelevant to the
    # shape — the whole body is scanned, exactly as `replay_shape` scans it.
    def inward_replay_shape(body, parameters)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        target, singleton = replayed_on(call.receiver, parameters)
        next unless target
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        ivar = pass.expression
        next unless ivar.is_a?(Prism::InstanceVariableReadNode)

        [target, ivar.name.to_s, singleton]
      end.uniq
      shapes.first if shapes.size == 1
    end

    # `<parameter>.class_eval do … end` — the inward replay with the block
    # written in place rather than fetched from a slot. Same receiver rule as
    # `inward_replay_shape` and for the same reason; what differs is only where
    # the block comes from, so what it answers is the block itself.
    def literal_replay_shape(body, parameters)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        target, singleton = replayed_on(call.receiver, parameters)
        next unless target
        block = call.block
        next unless block.is_a?(Prism::BlockNode)

        [call.name.to_s, block, singleton]
      end
      shapes.first if shapes.size == 1
    end

    # `<target>.class_eval(&block)` where `block` is the METHOD'S OWN parameter,
    # as `[name, dynamic?, singleton?]`.
    #
    # The mirror of `replay_shape`: there the receiver is the DSL's own `self`
    # and the block is fetched from the source object, here the block is the one
    # we were handed and the receiver is what may be somewhere else. So the
    # conservatism moves with it — what has to be decidable is the TARGET, and
    # `own_receiver` answers for the two spellings that name our own `self`
    # while `ConstantReference` answers for the two that name a constant.
    #
    # Anything else declines: a receiver that is a local, an ivar, or a method
    # call is an object this pass cannot name, and a block relocated onto the
    # wrong class is worse than one left where it was written.
    #
    # One shape per method, like the other replay readers. Two `class_eval`s of
    # one block onto two different targets is not something the source decides
    # for a caller — which of them a runtime dispatch reaches is the question
    # this pass declines rather than guesses at.
    def own_block_replay_shape(body, block_name)
      return nil unless block_name

      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::LocalVariableReadNode)
        next unless pass.expression.name.to_s == block_name

        replayed_onto(call.receiver, body)
      end.uniq

      shapes.first if shapes.size == 1
    end

    # What such a replay runs ON, as `[name, dynamic?, singleton?]`, or nil for a
    # receiver this pass will not name. A nil NAME is an answer rather than a
    # refusal: it is the DSL's own `self`, whoever that turns out to be at the
    # call site.
    #
    # A LOCAL is read through to what the body puts in it. `ActiveSupport` writes
    # the module to a local before evaluating into it, and so does anyone who
    # needs the name twice — a local is where you put a value you are about to
    # use, not an object this pass cannot name (felixefelip/rbs_infer#268).
    def replayed_onto(receiver, body)
      case own_receiver(receiver)
      when :instance then [nil, false, nil, false]
      when :singleton then [nil, false, nil, true]
      else
        return nil unless receiver

        named = if receiver.is_a?(Prism::LocalVariableReadNode)
                  local_constant(receiver.name.to_s, body)
                else
                  RbsInfer::AST::ConstantReference.named(receiver)
                end
        [*named, false] if named
      end
    end

    # The constant a local holds, when the body says so plainly: EVERY way it is
    # filled names the same one.
    #
    # Every way, because the two spellings of filling it conditionally are the
    # same claim — `mod = c ? A : B` is one assignment holding a conditional and
    # `if c then mod = A else mod = B end` is two assignments — and reading one
    # without the other would decide by syntax what Ruby decides by value. Arms
    # that disagree are the undecidable case and answer nothing, which is also
    # what an unassigned local answers: a parameter's value comes from the call
    # site, and that is a different shape entirely.
    def local_constant(name, body)
      writes = nodes(body).filter_map do |node|
        node.value if node.is_a?(Prism::LocalVariableWriteNode) && node.name.to_s == name
      end
      return nil if writes.empty?

      named = writes.flat_map { |value| constant_alternatives(value) }
      return nil if named.empty? || named.any?(&:nil?)

      answers = named.uniq { |constant, dynamic, _| [constant_key(constant), dynamic] }
      return nil unless answers.size == 1

      # Created by ANY of them. `const_defined?(:X) ? const_get(:X) : const_set(:X, …)`
      # is one claim written as two paths — the module is there afterwards either
      # way, and which path ran is exactly what the source does not say.
      constant, dynamic, = answers.first
      [constant, dynamic, named.filter_map { |_, _, creates| creates }.uniq.first]
    end

    # The constants an expression may evaluate to, as `named` answers them, with
    # a conditional read as its branches. Anything else is one expression and so
    # one alternative.
    #
    # `nil` is NO alternative rather than an unnamed one, and a missing branch is
    # that same nil: on such a path the local holds nothing, so `mod.module_eval`
    # raises and no block lands anywhere. Reading past it names the only module
    # the code can reach, which is what the rest of this pass does with a guard
    # (`if @block` changes nothing about which object is meant). Declining it
    # would also make `mod = A if c` and `mod = (if c then A end)` — the same
    # Ruby, written twice — answer differently.
    #
    # An alternative that is some OTHER expression is a different matter and
    # still declines: it may well be a module, and one this pass failed to name.
    def constant_alternatives(value)
      return [] if value.is_a?(Prism::NilNode)
      return [RbsInfer::AST::ConstantReference.named(value)] unless value.is_a?(Prism::IfNode)

      [value.statements, value.subsequent].compact.flat_map do |branch|
        statements = branch.respond_to?(:statements) ? branch.statements : branch
        (statements&.body || []).flat_map { |node| constant_alternatives(node) }
      end
    end

    # Two `named` answers are the same constant when they name the same thing:
    # a written one by its path, a fetched one by the name itself. Prism nodes
    # compare by identity, so the path is what has to be compared.
    def constant_key(constant)
      constant.is_a?(String) ? constant : RbsInfer::Analyzer.extract_constant_path(constant)
    end

    # `<parameter>.extend(<module>)` — every one the body writes, as
    # `[parameter, name, dynamic?]`.
    #
    # ALL of them rather than one, and no count to decline on. Two `class_eval`s
    # behind one name are an ambiguity — only one block can be the one meant —
    # but a hook that extends two modules has simply extended two modules, and
    # at runtime both happen. Same reason `forward_shapes` reports every forward.
    #
    # The receiver must be the parameter itself, with no `singleton_class` hop:
    # unlike a replay, where the hop names the other method table the same `def`s
    # could land in, `base.singleton_class.extend(M)` puts M in a third place
    # again — the singleton's own singleton — and nothing downstream can say that.
    #
    # The `if const_defined?(:ClassMethods)` guard `ActiveSupport::Concern`
    # writes around this is deliberately not read. What it asks is whether the
    # module is there, and `extension_name` answers that with the declarations
    # the pass has actually seen — the same question, decided by the project
    # rather than by re-implementing the condition.
    def inward_extend_shapes(body, parameters)
      nodes(body).flat_map do |node|
        next [] unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next [] unless call.name == :extend
        receiver = call.receiver
        next [] unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)

        (call.arguments&.arguments || []).filter_map do |argument|
          # Both spellings of naming a module, and the pair says which is which:
          # a constant is syntax and resolves in the file it was WRITTEN in, a
          # `const_get` is data and resolves against the `self` the hook runs on.
          named = RbsInfer::AST::ConstantReference.named(argument)
          [receiver.name.to_s, *named] if named
        end
      end
    end

    # `<parameter>.<callee>(self)` — handing ourselves to the object that holds
    # the block, which is the only way a target can start an inward replay.
    #
    # Exactly one argument, and it must be `self`: that is what makes the call a
    # request to act ON US, as against any other message this method might send
    # the parameter on the way.
    #
    # ALL of them, unlike the shapes above. A body sending the argument two such
    # messages is forwarding twice — that is what `include` does, and both halves
    # are real:
    #
    #   modules.reverse_each do |mod|
    #     mod.send(:append_features, self)
    #     mod.send(:included, self)
    #   end
    #
    # Reporting one shape and declining when there were two read that as an
    # ambiguity, and it is not one: which of the two leads to a stored block is
    # decided downstream, by whether the callee's keeper actually replays, and
    # `inward_slot` declines there if more than one does. The other shapes have
    # no such downstream evidence — two different ivars behind one `class_eval`
    # is undecidable wherever you ask — so they still decline on the count.
    def forward_shapes(body, parameters)
      nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        receiver = call.receiver
        next unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)
        arguments = call.arguments&.arguments || []
        next unless arguments.size == 1 && arguments.first.is_a?(Prism::SelfNode)

        [receiver.name.to_s, call.name.to_s]
      end.uniq
    end

    # `@holder ||= Holder.new` plus `@holder.<callee>(…, &block)` in one body.
    #
    # Forwarding the block is the whole claim. What separates a pass-through from
    # any other message the method happens to send its holder is that the block
    # the CALLER wrote arrives at the callee — and it is the only thing that
    # matters here, since the block is the object being relocated. A call that
    # drops it reaches a storage that would keep nothing.
    #
    # The constructor has to sit in this body too. An ivar filled somewhere else
    # is a data-flow question, and this pass answers only what one body shows —
    # the same line `inward_replay_shape` draws when it insists the block come
    # off `self` rather than from wherever a value might have been put.
    def delegation_shape(node)
      block_name = node.parameters&.block&.name&.to_s
      return nil unless block_name

      holders = held_constructions(node.body)
      return nil unless holders.size == 1

      ivar, constant = holders.first

      callees = nodes(node.body).filter_map do |child|
        next unless child.is_a?(Prism::CallNode)
        call = dispatched(child)
        receiver = call.receiver
        next unless receiver.is_a?(Prism::InstanceVariableReadNode) && receiver.name.to_s == ivar
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::LocalVariableReadNode)
        next unless pass.expression.name.to_s == block_name

        call.name.to_s
      end.uniq

      [constant, callees.first] if callees.size == 1
    end

    # Every ivar this body fills with a `Constant.new`, as `[ivar, constant]`.
    # `@x ||= K.new` and `@x = K.new` say the same thing about what the slot
    # holds. An ivar built from two different constants says nothing decidable
    # and is dropped rather than resolved by write order.
    def held_constructions(body)
      writes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::InstanceVariableWriteNode) || node.is_a?(Prism::InstanceVariableOrWriteNode)

        value = node.value
        next unless value.is_a?(Prism::CallNode) && value.name == :new && value.receiver

        [node.name.to_s, value.receiver]
      end

      writes.group_by(&:first).filter_map do |ivar, entries|
        constants = entries.map(&:last)
        names = constants.filter_map { |constant| RbsInfer::Analyzer.extract_constant_path(constant) }.uniq
        [ivar, constants.first] if names.size == 1
      end
    end

    def collect_class_body_call(node)
      case node.name
      when :extend
        return unless bare_or_self?(node) && node.arguments

        node.arguments.arguments.each do |argument|
          @extends << [current_scope, argument]
        end
      else
        return unless bare_or_self?(node)

        if node.block.is_a?(Prism::BlockNode)
          @stored_calls << StoredCall.new(owner: nil, subject: current_scope, method: node.name.to_s,
                                          block: node.block, source: @source)
        elsif node.arguments
          # One apply per argument. `apply(A, B)` asks for A's block AND B's,
          # which is what a `*modules` forward means at runtime — each gets its
          # own candidate, and each resolves (or declines) on its own evidence.
          # Only single-argument calls used to be read at all, so the plural
          # form resolved nothing (felixefelip/rbs_infer#253).
          node.arguments.arguments.each do |argument|
            @apply_calls << ApplyCall.new(owner: nil, subject: current_scope, method: node.name.to_s, argument: argument)
          end
        end
      end
    end

    def bare_or_self?(node)
      node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
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
    # Asked about `Module` and `Class` always, and about any `extend`/superclass
    # or APPLY ARGUMENT this file names but does not declare. A name the project
    # has nothing for simply yields no roots, which is the same as today's
    # answer.
    # Transitively, because a DSL chain is written across as many files as it
    # takes. A host includes a concern, the concern extends the module holding
    # the DSL, and the DSL is declared in a third file the host never names —
    # `Post` / `Post::Taggable` / `ActiveSupport::Concern`, which is the ordinary
    # shape rather than an exotic one. Reading one hop, the host saw the
    # concern's shapes and nothing about the DSL that gives the concern its
    # methods (felixefelip/rbs_infer#268).
    #
    # A worklist rather than a recursion, `seen`-guarded because two concerns
    # can name each other. It terminates because a project has finitely many
    # constants and each is asked about once; in practice the chain is two or
    # three files, and every parse and walk along it is memoized by file.
    def absorb_external_shapes
      queue = external_lookups.to_a
      seen = Set.new

      until queue.empty?
        # A lexical lookup, not a name: `include Fields` written in `class Filter`
        # means `Filter::Fields` if the project has one and top-level `Fields` if
        # it does not, and only the project can say which. Reading the name as
        # written asked for a `Fields` nobody declares, so the concern's file was
        # never opened and its `included do` never moved
        # (felixefelip/rbs_infer#289).
        name = resolve_lookup(queue.shift)
        next unless seen.add?(name)

        @sources.parsed_for(name).each do |entry|
          # Memoized per FILE, not per asking file: what a file says about its
          # own DSL is the same answer however many hosts ask, and a concern
          # used across an app is asked about by every one of them.
          shapes = @sources.derived(entry) do
            self.class.new(entry.source, sources: RbsInfer::Project::ConstantSources::NONE)
                .collect_shapes(entry.result.value)
          end
          absorb(shapes)
          # What THAT file reaches for, which is how the chain continues.
          queue.concat(shapes.external_lookups.to_a)
        end
        @declarations << name
      end
    end

    # The name a lookup lands on: the first candidate the project actually
    # declares, or — when it declares none of them — the name as written, which
    # is what this pass answered before it asked at all. Falling back rather
    # than dropping the lookup matters for the names a project never declares
    # in its own sources (`ApplicationRecord`, a gem's constant): they resolve
    # to themselves today and the chains reading them keep working.
    def resolve_lookup(candidates)
      candidates.find { |candidate| @sources.parsed_for(candidate).any? } || candidates.last
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
      @extends + @superclasses + @apply_calls.map { |apply| [apply.subject, apply.argument] }
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
        next if resolve_constant(raw_constant, subject)

        name = RbsInfer::Analyzer.extract_constant_path(raw_constant)
        lookups << lookup_candidates(name, subject) if name
      end

      lookups.uniq
    end

    # The names Ruby tries for `name` written in `subject`, in order. Mirrors
    # `resolve_constant`'s walk exactly — every enclosing prefix, longest first,
    # then the name alone — so a lookup answered here resolves there.
    #
    # An explicitly absolute `::Foo` names the top level and nothing else, which
    # is the one-element list.
    def lookup_candidates(name, subject)
      return [name.sub(/\A::/, "")] if name.start_with?("::")

      prefixes = subject.to_s.split("::")
      prefixes.length.downto(1).map { |length| "#{prefixes.take(length).join("::")}::#{name}" } + [name]
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
      @forwards.concat(shapes.forwards)
      @resolved_delegations.concat(shapes.resolved_delegations)
      @resolved_inward_extends.concat(shapes.resolved_inward_extends)
      @resolved_own_replays.concat(shapes.resolved_own_replays)
      # And what that file DECLARES, which no other shape needs: a `const_get`
      # is resolved under the module being included, and whether that module
      # holds the constant is a fact about the concern's own file.
      @absorbed_kinds.merge!(shapes.declaration_kinds)
      shapes.providers.each { |owner, subjects| @absorbed_providers[owner].merge(subjects) }
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

      providers = dsl_providers
      @resolved_delegations.concat(resolve_delegations)
      @resolved_inward_extends.concat(resolve_inward_extends)
      @resolved_own_replays.concat(resolve_own_replays)

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

      resolved += @apply_calls.filter_map { |apply| resolve_apply(apply, providers) }

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
      @created_kinds[target] = own.creates if own.name && own.creates
      kind = declared_kind(target)
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

    # The one block `apply` relocates, or nil when the file does not decide it.
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
      source_subject = resolve_constant(apply.argument, apply.subject)
      return nil unless source_subject

      # Two provider questions, not one. The applier is dispatched on the
      # SUBJECT (`banana` arrives in `Bar`'s body) and the callee it forwards
      # to on the ARGUMENT (`mod.send(:bananed, self)` runs on `Baz`), so the
      # two are answered by whatever supplies each — which need not be the
      # same module. Requiring one provider for both is what `ActiveSupport`'s
      # own shape breaks: `Module#include` reaches for `append_features`, a
      # method of the concern (felixefelip/rbs_infer#256).
      appliers = providers.select { |_, subjects| subjects.include?(apply.subject) }.keys
      sources = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      candidates = appliers.product(sources).filter_map do |applier, source_provider|
        replay_for(apply, applier, source_provider, source_subject)
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
      source_subject = resolve_constant(apply.argument, apply.subject)
      return [] unless source_subject

      kind = @declaration_kinds[apply.subject]
      return [] unless kind

      appliers = providers.select { |_, subjects| subjects.include?(apply.subject) }.keys
      sources = providers.select { |_, subjects| subjects.include?(source_subject) }.keys

      answers = appliers.product(sources).filter_map do |applier, source_provider|
        names = extension_names(applier, apply.method, source_provider, source_subject)
        names unless names.empty?
      end.uniq
      return [] unless answers.size == 1

      answers.first.map { |name| Extension.new(target: apply.subject, kind: kind, name: name) }
    end

    # The modules reached from `owner#method` that a hook extends its argument
    # with. Same walk as `inward_slot` — every forward, resolved through the
    # ARGUMENT's provider — differing only in what the keeper turns out to do
    # with what it was handed.
    def extension_names(owner, method, source_provider, source_subject)
      @forwards.flat_map do |forward|
        next [] unless forward.owner == owner && forward.method == method

        keeper_owner, keeper_method = keeper(source_provider, forward.callee)
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
      name if name && declared_module?(name)
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

      declared_kind(name) ? name : nil
    end

    # What a name is declared AS — "module", "class", or nil — in this file or in
    # one whose shapes were absorbed. Two callers want different halves of it: an
    # `extend` takes a module, so a class of that name is not the thing being
    # asked about; a replay takes either and needs the keyword to reopen it with.
    def declared_kind(name)
      @declaration_kinds[name] || @absorbed_kinds[name] || @created_kinds[name]
    end

    def declared_module?(name)
      declared_kind(name) == "module"
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
          resolved = resolve_constant(name, lexical_context(owner))
          next unless resolved && @declaration_kinds[resolved] == "module"

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
          resolved = resolve_constant(name, lexical_context(owner))
          next unless resolved

          OwnBlockReplay.new(owner: owner, method: method, name: resolved, dynamic: false, creates: creates,
                             singleton: singleton)
        end
      end
    end

    # The lexical scope a constant written in `owner`'s body resolves against.
    # `def self.included` is collected under `singleton(Foo)`, which names a
    # method table rather than a namespace: the constants a body there sees are
    # `Foo`'s.
    def lexical_context(owner)
      owner.to_s.sub(/\Asingleton\((.*)\)\z/, "\\1")
    end

    def replay_for(apply, applier, source_provider, source_subject)
      # Both directions answer with the SLOT — and with the object that owns
      # it, which is not always the provider: a delegating DSL method keeps
      # the block on something it holds. From there the chain is one and the
      # same: whoever fills that slot is the storage method, and the call the
      # source wrote under that name holds the block. Asking both and
      # requiring a single answer is what keeps a file that somehow reads as
      # both from being resolved by declaration order.
      slots = [outward_slot(applier, apply.method),
               inward_slot(applier, apply.method, source_provider)].compact.uniq
      # And the third way to reach a block: not through a slot at all,
      # because the replaying method wrote it in place. Counted together
      # with the slots, so a file reading as both still declines.
      literals = literal_replays_for(applier, apply.method, source_provider)
      return nil unless slots.size + literals.size == 1

      kind = @declaration_kinds[apply.subject]
      return nil unless kind

      if (literal = literals.first)
        return Replay.new(target: apply.subject, block: literal.block, kind: kind,
                          call: literal.call, scope: literal.scope, in_method: literal.method,
                          source: literal.source, singleton: literal.singleton, extended: false)
      end

      storage_owner, ivar, singleton = slots.first
      # The SOURCE's provider, not the applier's: the name being looked up
      # is the one the source wrote in its own body.
      storage_method = storage_method_for(source_provider, storage_owner, ivar)
      return nil unless storage_method

      blocks = @stored_calls.select { |stored| stored.subject == source_subject && stored.method == storage_method }
      return nil unless blocks.size == 1

      Replay.new(target: apply.subject, block: blocks.first.block, kind: kind,
                 call: storage_method, scope: blocks.first.subject, in_method: nil,
                 source: blocks.first.source, singleton: singleton, extended: false)
    end

    # Which classes/modules can call each owner's DSL, as `owner => subjects`.
    #
    # `extend Builder` is one way to be handed those methods; `class Sub < Base`
    # is the other, and to a caller they are indistinguishable — `bazingado`
    # arrives with no receiver in the class body either way. Reading only the
    # first was the whole reason a file spelling the same replay through
    # inheritance produced nothing (felixefelip/rbs_infer#251).
    #
    # Ancestry is transitive because Ruby's is: `Bar < Baz < Foo` puts Foo's
    # singleton methods in Bar's body just as directly as `Bar < Foo` would.
    def dsl_providers
      providers = Hash.new { |hash, key| hash[key] = Set.new }
      @absorbed_providers.each { |owner, subjects| providers[owner].merge(subjects) }

      @extends.each do |subject, raw_module|
        mod = resolve_constant(raw_module, subject) || written_constant(raw_module)
        providers[mod] << subject if mod
      end

      parents = @superclasses.to_h do |subject, raw_superclass|
        [subject, resolve_constant(raw_superclass, subject)]
      end
      parents.compact!

      # Through the SINGLETON, both of them. `keep` in a class body is a call on
      # the class object, so it is found in `singleton(Base)` — where
      # `def self.keep` put it — and never in `Base`'s own method table, where
      # `extend`'s half lives. Keyed alike, an `attr_reader :body` in a class
      # body would answer for a `def self.apply` that could not call it.
      @declarations.each do |subject|
        providers[singleton_owner(subject)] << subject
        superclasses(subject, parents).each { |ancestor| providers[singleton_owner(ancestor)] << subject }
      end

      # What the subject's own `self` makes callable: a class body reaches
      # `Class`'s instance methods and everything behind them, a module body
      # `Module`'s. To the caller this is indistinguishable from the two
      # relations above — the method arrives with no receiver either way — but
      # it is neither an `extend` nor an ancestor of the SUBJECT, so nothing
      # above can express it, and a DSL whose applier is written as a core
      # reopening had no provider at all (felixefelip/rbs_infer#256).
      #
      # Costless when nothing reopens them: an owner with no collected shapes
      # answers no slot, so the join declines exactly where it declines today.
      @declaration_kinds.each do |subject, kind|
        CORE_SELF_CHAINS.fetch(kind, []).each { |ancestor| providers[ancestor] << subject }
      end

      providers
    end

    # The name an `extend` writes, for a module this file does not declare.
    #
    # `resolve_constant` answers nil for those, and rightly: it is picking a
    # NAMESPACE, and only a declaration it can see settles which one. A provider
    # key needs no such confirmation — it either matches the shapes some other
    # file supplied or it matches nothing, and a name nobody supplies methods
    # under changes no answer. Without the fallback, a concern extending a DSL
    # declared in another file recorded no provider at all, so the host holding
    # both halves could not join them (felixefelip/rbs_infer#268).
    def written_constant(node)
      RbsInfer::Analyzer.extract_constant_path(node)&.sub(/\A::/, "")
    end

    # `subject`'s superclass chain, nearest first, limited to classes declared
    # in this file. A chain that revisits a class it already yielded stops
    # there: `class A < B` reopened as `class B < A` is not something to reason
    # about, but it must not hang the pass either.
    def superclasses(subject, parents)
      chain = []
      current = parents[subject]
      while current && !chain.include?(current)
        chain << current
        current = parents[current]
      end
      chain
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
      slots = @forwards.filter_map do |forward|
        next unless forward.owner == owner && forward.method == method

        # The callee runs on the ARGUMENT, so it is the argument's provider that
        # has to supply it — reading it off the forward's own owner only works
        # while one module happens to hold both halves of the DSL.
        keeper_owner, keeper_method = keeper(source_provider, forward.callee)
        next unless keeper_owner

        replays = @inward_replays.select { |replay| replay.owner == keeper_owner && replay.method == keeper_method }
        [keeper_owner, replays.first.ivar, replays.first.singleton] if replays.size == 1
      end.uniq

      slots.first if slots.size == 1
    end

    # The replays reached from `owner#method` that carry their own block. Same
    # walk as `inward_slot` — every forward, resolved through the ARGUMENT's
    # provider — differing only in what the keeper turns out to hold.
    def literal_replays_for(owner, method, source_provider)
      @forwards.filter_map do |forward|
        next unless forward.owner == owner && forward.method == method

        keeper_owner, keeper_method = keeper(source_provider, forward.callee)
        next unless keeper_owner

        replays = @literal_replays.select { |replay| replay.owner == keeper_owner && replay.method == keeper_method }
        replays.first if replays.size == 1
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
      delegations = @resolved_delegations.select { |it| it.owner == owner && it.method == method }
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

      @resolved_delegations.each do |delegation|
        next unless delegation.owner == provider
        next unless delegation.target == storage_owner && delegation.callee == storage_method

        names << delegation.method
      end

      names.uniq
    end

    def resolve_delegations
      @delegations.filter_map do |owner, method, raw_target, callee|
        target = resolve_constant(raw_target, owner)
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

    def nodes(root)
      return [] unless root

      RbsInfer::Analyzer.find_all_nodes(root) { true }
    end
  end
end
