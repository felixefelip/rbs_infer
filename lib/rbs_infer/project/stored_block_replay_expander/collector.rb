# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../inference/send_call"

module RbsInfer::Project::StoredBlockReplayExpander
  # Collects declarations and class-body calls in one lexical pass. It keeps
  # syntax, not guessed types: resolving `Foo` in `extend Foo` and `Baz` in
  # `apply(Baz)` uses the declarations that are actually present in the file.
  class Collector < Prism::Visitor
    Storage = Data.define(:owner, :method, :ivar)
    ReplayMethod = Data.define(:owner, :method, :parameter, :reader)
    StoredCall = Data.define(:owner, :subject, :method, :block)
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
    InwardReplay = Data.define(:owner, :method, :parameter, :ivar)

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

    def initialize(source)
      @source = source
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
      resolve_replays
    end

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
      params = node.parameters
      block_name = params&.block&.name&.to_s
      method_name = node.name.to_s

      if block_name && (ivar = stored_block_ivar(node.body, block_name))
        @storages << Storage.new(owner: current_scope, method: method_name, ivar: ivar)
      end

      if (replay = replay_shape(node.body))
        parameter, reader = replay
        @replay_methods << ReplayMethod.new(owner: current_scope, method: method_name, parameter: parameter, reader: reader)
      end

      parameters = handed_names(node.body, parameter_names(params))

      if (inward = inward_replay_shape(node.body, parameters))
        parameter, ivar = inward
        @inward_replays << InwardReplay.new(owner: current_scope, method: method_name, parameter: parameter, ivar: ivar)
      end

      if (delegation = delegation_shape(node))
        target, callee = delegation
        @delegations << [current_scope, method_name, target, callee]
      end

      return unless (forward = forward_shape(node.body, parameters))

      parameter, callee = forward
      @forwards << ForwardMethod.new(owner: current_scope, method: method_name, parameter: parameter, callee: callee)
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

        [reader.receiver.name.to_s, reader.name.to_s]
      end.uniq
      shapes.first if shapes.size == 1
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
        receiver = call.receiver
        next unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        ivar = pass.expression
        next unless ivar.is_a?(Prism::InstanceVariableReadNode)

        [receiver.name.to_s, ivar.name.to_s]
      end.uniq
      shapes.first if shapes.size == 1
    end

    # `<parameter>.<callee>(self)` — handing ourselves to the object that holds
    # the block, which is the only way a target can start an inward replay.
    #
    # Exactly one argument, and it must be `self`: that is what makes the call a
    # request to act ON US, as against any other message this method might send
    # the parameter on the way.
    def forward_shape(body, parameters)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        receiver = call.receiver
        next unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)
        arguments = call.arguments&.arguments || []
        next unless arguments.size == 1 && arguments.first.is_a?(Prism::SelfNode)

        [receiver.name.to_s, call.name.to_s]
      end.uniq
      shapes.first if shapes.size == 1
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
          @stored_calls << StoredCall.new(owner: nil, subject: current_scope, method: node.name.to_s, block: node.block)
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

    def resolve_replays
      # `attr_reader :body` is collected from its lexical owner after all
      # declarations are known, so a relative `extend Builder` can resolve.
      collect_readers_from_source

      providers = dsl_providers
      @resolved_delegations = resolve_delegations

      candidates = []
      @apply_calls.each do |apply|
        providers.each do |owner, subjects|
          next unless subjects.include?(apply.subject)

          source_subject = resolve_constant(apply.argument, apply.subject)
          next unless source_subject && subjects.include?(source_subject)

          # Both directions answer with the SLOT — and with the object that owns
          # it, which is not always the provider: a delegating DSL method keeps
          # the block on something it holds. From there the chain is one and the
          # same: whoever fills that slot is the storage method, and the call the
          # source wrote under that name holds the block. Asking both and
          # requiring a single answer is what keeps a file that somehow reads as
          # both from being resolved by declaration order.
          slots = [outward_slot(owner, apply.method), inward_slot(owner, apply.method)].compact.uniq
          next unless slots.size == 1

          storage_owner, ivar = slots.first
          storage_method = storage_method_for(owner, storage_owner, ivar)
          next unless storage_method

          blocks = @stored_calls.select { |stored| stored.subject == source_subject && stored.method == storage_method }
          next unless blocks.size == 1

          kind = @declaration_kinds[apply.subject]
          next unless kind

          candidates << Replay.new(target: apply.subject, block: blocks.first.block, kind: kind,
                                   call: storage_method, scope: blocks.first.subject)
        end
      end

      by_block = candidates.group_by { |candidate| candidate.block.location.start_offset }
      by_block.values.filter_map do |entries|
        targets = entries.map(&:target).uniq
        entries.first if targets.size == 1
      end
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

      @declarations.each do |subject|
        superclasses(subject, parents).each { |ancestor| providers[ancestor] << subject }
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
      [owner, ivars.first] if ivars.size == 1
    end

    # The slot behind `param.class_eval(&@ivar)`, when `method` only FORWARDS to
    # the replay. One hop, not a chain: each additional link is another place a
    # runtime value could be substituted for the constant we resolved, and this
    # pass has no way to tell that it wasn't.
    def inward_slot(owner, method)
      forwards = @forwards.select { |forward| forward.owner == owner && forward.method == method }
      return nil unless forwards.size == 1

      keeper_owner, keeper_method = keeper(owner, forwards.first.callee)
      return nil unless keeper_owner

      replays = @inward_replays.select { |replay| replay.owner == keeper_owner && replay.method == keeper_method }
      [keeper_owner, replays.first.ivar] if replays.size == 1
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
