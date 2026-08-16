# frozen_string_literal: true

require "prism"
require "set"

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

    SEND_METHODS = %i[send public_send __send__].freeze

    # What a call actually dispatches: `[method_name, arguments]`.
    #
    # `send` and its siblings name their callee in the first ARGUMENT, so
    # `x.send(:foo, a)` is statically the same call as `x.foo(a)` — the
    # indirection is a spelling, not a data-flow question, as long as that
    # first argument is a literal name. Reading `node.name` directly answered
    # `send` and left the real callee sitting in the argument list, so every
    # shape below silently missed the spelling (felixefelip/rbs_infer#255).
    #
    # That spelling is exactly what a caller reaches for when the method is
    # private, which is why a DSL keeping its storage method private was
    # invisible — and it is what the generated `Module#include` pseudo-code
    # writes (`mod.send(:included, self)`), for the same reason.
    #
    # A COMPUTED name (`x.send(meth, a)`) is the arbitrary-dispatch case this
    # pass exists to decline: nil, so the caller skips the node rather than
    # guessing which method runs.
    def dispatched(node)
      arguments = node.arguments&.arguments || []
      return [node.name, arguments] unless SEND_METHODS.include?(node.name)

      callee, *rest = arguments
      return nil unless callee.is_a?(Prism::SymbolNode) || callee.is_a?(Prism::StringNode)

      [callee.unescaped.to_sym, rest]
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
        evaluator, = dispatched(node)
        next unless evaluator && REPLAY_METHODS.include?(evaluator)
        pass = node.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        reader_call = pass.expression
        next unless reader_call.is_a?(Prism::CallNode)
        reader, reader_arguments = dispatched(reader_call)
        next unless reader && reader_arguments.empty?
        next unless reader_call.receiver.is_a?(Prism::LocalVariableReadNode)

        [reader_call.receiver.name.to_s, reader.to_s]
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
        evaluator, = dispatched(node)
        next unless evaluator && REPLAY_METHODS.include?(evaluator)
        receiver = node.receiver
        next unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)
        pass = node.block
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
        receiver = node.receiver
        next unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)
        callee, arguments = dispatched(node)
        next unless callee
        next unless arguments.size == 1 && arguments.first.is_a?(Prism::SelfNode)

        [receiver.name.to_s, callee.to_s]
      end.uniq
      shapes.first if shapes.size == 1
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

      candidates = []
      @apply_calls.each do |apply|
        providers.each do |owner, subjects|
          next unless subjects.include?(apply.subject)

          source_subject = resolve_constant(apply.argument, apply.subject)
          next unless source_subject && subjects.include?(source_subject)

          # Both directions answer with the SLOT, and from there the chain is
          # one and the same: whoever fills that slot is the storage method, and
          # the call the source wrote under that name holds the block. Asking
          # both and requiring a single answer is what keeps a file that somehow
          # reads as both from being resolved by declaration order.
          ivars = [outward_ivar(owner, apply.method), inward_ivar(owner, apply.method)].compact.uniq
          next unless ivars.size == 1

          storage_method = storage_method_for(owner, ivars.first)
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
    def outward_ivar(owner, method)
      replays = @replay_methods.select { |replay| replay.owner == owner && replay.method == method }
      return nil unless replays.size == 1

      ivars = @readers.select { |reader_owner, name, _| reader_owner == owner && name == replays.first.reader }
      ivars = ivars.map(&:last).uniq
      ivars.first if ivars.size == 1
    end

    # The slot behind `param.class_eval(&@ivar)`, when `method` only FORWARDS to
    # the replay. One hop, not a chain: each additional link is another place a
    # runtime value could be substituted for the constant we resolved, and this
    # pass has no way to tell that it wasn't.
    def inward_ivar(owner, method)
      forwards = @forwards.select { |forward| forward.owner == owner && forward.method == method }
      return nil unless forwards.size == 1

      replays = @inward_replays.select { |replay| replay.owner == owner && replay.method == forwards.first.callee }
      replays.first.ivar if replays.size == 1
    end

    # The one method in `owner` that fills `ivar` — the other half of the join,
    # and the name the source's block was written under. Exactly one, and it must
    # fill exactly that one slot: a method storing into two ivars cannot say
    # which block a later replay is asking for.
    def storage_method_for(owner, ivar)
      entries = @storages.group_by { |storage| [storage.owner, storage.method] }.select do |(storage_owner, _), storages|
        storage_owner == owner && storages.size == 1 && storages.first.ivar == ivar
      end
      entries.keys.first.last if entries.size == 1
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
