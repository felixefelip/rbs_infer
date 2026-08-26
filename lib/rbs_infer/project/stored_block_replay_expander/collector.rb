# frozen_string_literal: true

require "prism"
require "set"
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
      self
    end

    protected

    attr_reader :storages, :readers, :replay_methods, :inward_replays, :forwards, :resolved_delegations,
                :literal_replays, :stored_calls

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

      name = name.sub(/\A::/, "")
      return name if name.include?("::") && @declarations.include?(name)
      return name if name.start_with?("::")

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
    def absorb_external_shapes
      external_owners.each do |name|
        @sources.parsed_for(name).each do |entry|
          # Memoized per FILE, not per asking file: what a file says about its
          # own DSL is the same answer however many hosts ask, and a concern
          # used across an app is asked about by every one of them.
          shapes = @sources.derived(entry) do
            self.class.new(entry.source, sources: RbsInfer::Project::ConstantSources::NONE)
                .collect_shapes(entry.result.value)
          end
          absorb(shapes)
        end
        @declarations << name
      end
    end

    def external_owners
      names = Set.new(CORE_REOPENS)

      external_constants.each do |subject, raw_constant|
        next if resolve_constant(raw_constant, subject)

        name = RbsInfer::Analyzer.extract_constant_path(raw_constant)
        names << name.sub(/\A::/, "") if name
      end

      names
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

    def absorb(shapes)
      @storages.concat(shapes.storages)
      @readers.concat(shapes.readers)
      @replay_methods.concat(shapes.replay_methods)
      @inward_replays.concat(shapes.inward_replays)
      @forwards.concat(shapes.forwards)
      @resolved_delegations.concat(shapes.resolved_delegations)
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

      resolved = @apply_calls.filter_map { |apply| resolve_apply(apply, providers) }

      # Two apply calls naming the same source in the same class body are one
      # replay written twice, not two — the block relocates to that class once.
      # Keyed on the block's own SOURCE as well as its offset, since two files
      # hold blocks at the same offset all the time and a location says nothing
      # about which file it indexes.
      resolved.uniq { |replay| [replay.target, replay.singleton, replay.source, replay.block.location.start_offset] }
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
                          source: literal.source, singleton: literal.singleton)
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
                 source: blocks.first.source, singleton: singleton)
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

      @extends.each do |subject, raw_module|
        mod = resolve_constant(raw_module, subject)
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
