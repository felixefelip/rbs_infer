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

      parameters = parameter_names(params)

      if (inward = inward_replay_shape(node.body, parameters))
        parameter, ivar = inward
        @inward_replays << InwardReplay.new(owner: current_scope, method: method_name, parameter: parameter, ivar: ivar)
      end

      return unless (forward = forward_shape(node.body, parameters))

      parameter, callee = forward
      @forwards << ForwardMethod.new(owner: current_scope, method: method_name, parameter: parameter, callee: callee)
    end

    # Every name the method can be HANDED an object under. A replay against
    # arbitrary state is what this pass declines to guess about, so both shapes
    # below require their receiver to be one of these rather than any local that
    # happens to be in scope.
    def parameter_names(params)
      return Set.new unless params.is_a?(Prism::ParametersNode)

      names = params.requireds + params.optionals + params.posts + params.keywords
      names = names.filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
      names << params.rest.name.to_s if params.rest.respond_to?(:name) && params.rest&.name
      Set.new(names)
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
        next unless node.is_a?(Prism::CallNode) && REPLAY_METHODS.include?(node.name)
        pass = node.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        reader_call = pass.expression
        next unless reader_call.is_a?(Prism::CallNode) && reader_call.arguments.nil?
        next unless reader_call.receiver.is_a?(Prism::LocalVariableReadNode)

        [reader_call.receiver.name.to_s, reader_call.name.to_s]
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
        next unless node.is_a?(Prism::CallNode) && REPLAY_METHODS.include?(node.name)
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
        arguments = node.arguments&.arguments || []
        next unless arguments.size == 1 && arguments.first.is_a?(Prism::SelfNode)

        [receiver.name.to_s, node.name.to_s]
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
        elsif node.arguments && node.arguments.arguments.size == 1
          @apply_calls << ApplyCall.new(owner: nil, subject: current_scope, method: node.name.to_s, argument: node.arguments.arguments.first)
        end
      end
    end

    def bare_or_self?(node)
      node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    def resolve_replays
      extenders = Hash.new { |hash, key| hash[key] = Set.new }
      @extends.each do |subject, raw_module|
        mod = resolve_constant(raw_module, subject)
        extenders[mod] << subject if mod
      end

      # `attr_reader :body` is collected from its lexical owner after all
      # declarations are known, so a relative `extend Builder` can resolve.
      collect_readers_from_source

      candidates = []
      @apply_calls.each do |apply|
        extenders.each do |owner, subjects|
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
