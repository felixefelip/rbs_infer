module RbsInfer::Inference
  class NewCallCollector < Prism::Visitor
    attr_reader :usages, :method_call_usages, :method_block_returns

    # Collect the fully-qualified names of every class/module DEFINED in a
    # parsed file, so `match_class?` can tell a bare `Foo` written inside
    # `Example3` (→ `Example3::Foo`) apart from a same-named class elsewhere
    # (`Example2::Foo`). Order-independent: gathered up front, not during the
    # main call-collecting traversal.
    def self.collect_defined_class_names(root_node)
      names = Set.new
      stack = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        pushed = nil
        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
          if segment
            pushed = stack.empty? ? segment : "#{stack.last}::#{segment}"
            names << pushed
            stack.push(pushed)
          end
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
        stack.pop if pushed
      end
      walk.call(root_node)
      names
    end

    def initialize(target_class:, method_return_types:, local_var_types:, constant_arg_resolver:, defined_class_names:, module_self_types:, invoker_self_types:, inherited_forwards:, inherited_initializers:, inherited_supers:,
                   local_var_read_types: {}, local_var_types_by_method: {}, method_type_resolver: nil, caller_class_name: nil, init_positional_params: [], target_methods: {}, match_bare_calls: false, self_types_by_method: {}, established_ivars_by_method: {}, argument_partitions_by_method: {}, block_methods: Set.new, expression_types: {}, method_owners: {})
      @receivers = ReceiverMatcher.new(target_class: target_class, method_owners: method_owners, defined_class_names: defined_class_names)
      @scope = Scope.new(local_var_types: local_var_types, caller_class_name: caller_class_name)
      @types = ValueTypes.new(scope: @scope, method_return_types: method_return_types, local_var_read_types: local_var_read_types,
                              method_type_resolver: method_type_resolver, constant_arg_resolver: constant_arg_resolver,
                              self_types_by_method: self_types_by_method, module_self_types: module_self_types, invoker_self_types: invoker_self_types)
      @arguments = CallArguments.new(value_types: @types, expression_types: expression_types, init_positional_params: init_positional_params)
      @local_var_types_by_method = local_var_types_by_method
      @method_scoped_var_names = local_var_types_by_method.each_value.flat_map(&:keys).to_set
      @assigned_types = AssignedTypes.new(method_return_types: method_return_types, method_type_resolver: method_type_resolver, caller_class_name: caller_class_name)
      @target_methods = target_methods
      @inherited_forwards = inherited_forwards
      @inherited_initializers = inherited_initializers
      @inherited_supers = inherited_supers
      @match_bare_calls = match_bare_calls
      @established_ivars_by_method = established_ivars_by_method
      @argument_partitions_by_method = argument_partitions_by_method
      @block_methods = block_methods
      @expression_types = expression_types
      @usages = []
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
      @method_block_returns = Hash.new { |h, k| h[k] = [] }
    end

    def visit_module_node(node)
      @scope.in_module(node) { super }
    end

    def visit_class_node(node)
      @assigned_types.from_class(node, into: @scope.local_var_types)
      @scope.in_class(node) { super }
    end

    def visit_def_node(node)
      @scope.in_def(node) do
        unless @method_scoped_var_names.empty?
          @scope.local_var_types = @scope.local_var_types.reject { |name, _| @method_scoped_var_names.include?(name) }
          @scope.local_var_types.merge!(@local_var_types_by_method[@scope.current_method] || {})
        end
        @assigned_types.from_def(node, into: @scope.local_var_types)
        super
      end
    end

    def visit_super_node(node)
      if super_reaches_target_initialize?
        args = @arguments.for_initialize(node)
        @usages << args unless args.empty?
      elsif super_reaches_target_method?
        read_super_as_call(node, @scope.current_method)
      end
      super
    end

    def read_super_as_call(node, method_name)
      if (params = @target_methods[method_name])
        args = @arguments.for_params(node, params)
        @method_call_usages[method_name] << args unless args.empty?
      end
      return unless @block_methods.include?(method_name) && node.block.is_a?(Prism::BlockNode)

      type = BlockReturnCollector.block_return_type(node.block, @expression_types)
      @method_block_returns[method_name] << type if type
    end

    # A `case <param> ... when <literal>` branch is reachable only for callers who passed
    # that literal, so the facts the fork recorded for that (param, literal) partition hold
    # inside it — and only inside it. Each branch body is visited with those ivars merged
    # in, then the table is restored, so a sibling branch and everything after the `case`
    # are unaffected.
    #
    # This is what lets a shared dispatcher stay precise: a controller's `render` override
    # is one method reached from every action, so its ivars are the meet over all of them;
    # the partition is what says "on the :edit path, `@post` was established".
    def visit_case_node(node)
      partitions = partitions_for_case(node)
      return super if partitions.empty?

      node.conditions.each do |clause|
        next unless clause.is_a?(Prism::WhenNode)

        ivars = clause.conditions.filter_map { |c| partitions[literal_key(c)] }.reduce({}, :merge)
        if ivars.empty?
          clause.statements&.accept(self)
          next
        end

        @scope.with_local_types(ivars) { clause.statements&.accept(self) }
      end

      node.else_clause&.accept(self)
      node.predicate&.accept(self)
      nil
    end

    def visit_call_node(node) # rubocop:todo Metrics/MethodLength
      node = SendCall.desugar(node) || node unless @target_methods.key?("send")

      apply_established_ivars(node)

      if node.name == :new && node.receiver
        receiver_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
        if receiver_name && (match_class?(receiver_name) || constructs_target?(node.receiver))
          args = @arguments.for_initialize(node)
          @usages << args unless args.empty?
        end
      end

      # Cross-class method calls: receiver.method(args) onde receiver é do tipo target_class
      if !@target_methods.empty? && node.receiver && node.arguments
        method_name = node.name.to_s
        if @target_methods.key?(method_name)
          receiver_type = @types.receiver_type(node.receiver)
          @receivers.keys_by_branch(receiver_type, method_name, namespace: @scope.lexical_class_name).each do |key, branches|
            args = extract_cross_class_args_for(node, method_name, branches)
            @method_call_usages[key] << args unless args.empty?
          end
        end
      end

      # The call site of an INHERITED dispatcher (felixefelip/rbs_infer#331):
      # `Greeter.dispatch("ada", greeting: "hi")` runs `Greeter#handle`, because
      # `new` inside the base's singleton method is the receiver of the call. The
      # arguments are mapped onto the handler's parameters exactly as a direct
      # `greeter.handle("ada", greeting: "hi")` would be — the forward is only
      # recognized when it splats its rest and keyrest and nothing else, which is
      # what makes the positions line up.
      #
      # `match_class?` is the receiver filter, and it is the whole point: the
      # ancestry match that already accepts this call site keys it on the bare
      # method name, so every subclass's arguments merge into the base's
      # parameter. Here the receiver has to BE the target.
      if !@inherited_forwards.empty? && singleton_receiver_spelling?(node.receiver) && node.arguments
        Array(@inherited_forwards[node.name.to_s]).each do |forwarded_to|
          next unless @target_methods.key?(forwarded_to)

          receiver_type = @types.receiver_type(node.receiver)
          next unless receiver_type && @receivers.reaches_target_method?(receiver_type, forwarded_to)

          args = @arguments.for_params(node, @target_methods[forwarded_to])
          @method_call_usages[forwarded_to] << args unless args.empty?
        end
      end

      if !@block_methods.empty? && node.block.is_a?(Prism::BlockNode) && @block_methods.include?(node.name.to_s) &&
         (node.receiver.nil? ? @match_bare_calls : block_receiver_matches?(node))
        type = BlockReturnCollector.block_return_type(node.block, @expression_types)
        @method_block_returns[node.name.to_s] << type if type
      end

      # Bare method calls matching target_methods (for included modules, e.g. helpers in ERB views)
      if !@target_methods.empty? && node.receiver.nil? && node.arguments && @match_bare_calls
        method_name = node.name.to_s
        if @target_methods.key?(method_name)
          args = @arguments.for_params(node, @target_methods[method_name])
          @method_call_usages[method_name] << args unless args.empty?
        end
      end

      super
    end

    private

    def match_class?(name)
      @receivers.match_class?(name, namespace: @scope.lexical_class_name)
    end

    def block_receiver_matches?(node)
      receiver_type = @types.receiver_type(node.receiver)
      receiver_type && match_class?(receiver_type)
    end

    def apply_established_ivars(node)
      return if @established_ivars_by_method.empty?
      return unless node.receiver.nil?

      established = @established_ivars_by_method[node.name.to_s] or return
      established.each { |ivar, type| @scope.local_var_types[ivar] = type }
    end

    # `{ literal_key => ivars }` for the partitions keyed on this `case`'s subject, or `{}`.
    # Only a bare read of a METHOD PARAMETER qualifies: the correlation is between the
    # caller's argument and the branch, and a `case` on anything else says nothing about
    # what the caller passed.
    def partitions_for_case(node)
      return {} if @argument_partitions_by_method.empty?
      return {} unless @scope.current_method

      predicate = node.predicate
      return {} unless predicate.is_a?(Prism::LocalVariableReadNode)

      param = predicate.name.to_s
      (@argument_partitions_by_method[@scope.current_method] || []).each_with_object({}) do |partition, acc|
        next unless partition[:param] == param

        acc[partition[:pattern]] = partition[:ivars]
      end
    end

    # The canonical literal string the fork's `Postconditions::LiteralKey` produces, so a
    # `when` pattern here matches the `pattern` recorded there. Both sides must spell the
    # same literal the same way or nothing correlates.
    def literal_key(node)
      case node
      when Prism::SymbolNode then ":#{node.value}"
      when Prism::StringNode then node.unescaped.inspect
      when Prism::IntegerNode, Prism::FloatNode then node.slice
      when Prism::TrueNode then "true"
      when Prism::FalseNode then "false"
      when Prism::NilNode then "nil"
      end
    end

    def extract_cross_class_args_for(node, method_name, branches)
      @scope.with_self_condition(self_condition(node, branches)) { @arguments.for_params(node, @target_methods[method_name]) }
    end

    # `[parameter index, branch]`, or nil when the pairing cannot be stated.
    def self_condition(node, branches)
      return nil unless branches.size == 1
      return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)

      index = @scope.current_def_params.index(node.receiver.name.to_s) or return nil
      [index, branches.first]
    end

    # A dispatcher is inherited onto the CLASS, so only a call made on the class
    # object can be one. Without this, an instance method that happens to share
    # the forward's name — `run`, `call`, `process` are all plausible — would
    # have its arguments filed against the handler: `x.run(config)` with
    # `x : Greeter` is a legitimate, unrelated call.
    def singleton_receiver_spelling?(receiver)
      case receiver
      when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::SelfNode then true
      when nil then false
      else @types.receiver_type(receiver).to_s.start_with?("singleton(")
      end
    end

    # `Kid.new(...)` where the `initialize` `Kid` runs is the target's: an
    # inherited one is a call site whatever the receiver is called
    # (felixefelip/rbs_infer#412).
    def constructs_target?(receiver)
      return false if @inherited_initializers.constructs.empty?
      return false unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      resolved = @types.constant_type(receiver)[/\Asingleton\((.+)\)\z/, 1] or return false
      @inherited_initializers.constructs.include?(resolved.delete_prefix("::"))
    end

    # A `super` written in an `initialize` of a class's own body, in a class
    # whose `super` reaches the target's.
    def super_reaches_target_initialize?
      return false if @inherited_initializers.supers.empty?
      return false unless @scope.current_method == "initialize" && @scope.own_method_side == :instance

      @inherited_initializers.supers.include?(@scope.lexical_name)
    end

    # The same for any other target method, on either side: a `super` in the
    # class's own method of that name, in a class whose `super` reaches the
    # target's.
    def super_reaches_target_method?
      return false if @inherited_supers.empty?

      side = @scope.own_method_side or return false
      classes = @inherited_supers.dig(side, @scope.current_method) or return false
      classes.include?(@scope.lexical_name)
    end
  end
end
