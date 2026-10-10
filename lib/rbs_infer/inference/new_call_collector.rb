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

    # rubocop:todo-next Metrics/MethodLength
    def initialize(target_class:, method_return_types:, local_var_types:, constant_arg_resolver:, defined_class_names:, module_self_types:, invoker_self_types:, inherited_forwards:, inherited_initializers:, inherited_supers:,
                   local_var_read_types: {}, local_var_types_by_method: {}, method_type_resolver: nil, caller_class_name: nil, init_positional_params: [], target_methods: {}, match_bare_calls: false, self_types_by_method: {}, established_ivars_by_method: {}, argument_partitions_by_method: {}, block_methods: Set.new, expression_types: {}, method_owners: {})
      @receivers = ReceiverMatcher.new(target_class: target_class, method_owners: method_owners, defined_class_names: defined_class_names)
      @arguments = CallArguments.new(value_type: method(:resolve_value_type), expression_types: expression_types, init_positional_params: init_positional_params)
      @method_return_types = method_return_types
      @local_var_types = local_var_types
      @local_var_read_types = local_var_read_types
      @local_var_types_by_method = local_var_types_by_method
      @method_scoped_var_names = local_var_types_by_method.each_value.flat_map(&:keys).to_set
      @method_type_resolver = method_type_resolver
      @caller_class_name = caller_class_name
      @assigned_types = AssignedTypes.new(method_return_types: method_return_types, method_type_resolver: method_type_resolver, caller_class_name: caller_class_name)
      @constant_arg_resolver = constant_arg_resolver
      @target_methods = target_methods
      @inherited_forwards = inherited_forwards
      @inherited_initializers = inherited_initializers
      @inherited_supers = inherited_supers
      @match_bare_calls = match_bare_calls
      @self_types_by_method = self_types_by_method
      @module_self_types = module_self_types
      @invoker_self_types = invoker_self_types
      @current_def_params = []
      @self_condition = nil
      @established_ivars_by_method = established_ivars_by_method
      @argument_partitions_by_method = argument_partitions_by_method
      @block_methods = block_methods
      @expression_types = expression_types
      @usages = []
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
      @method_block_returns = Hash.new { |h, k| h[k] = [] }
      @class_name_stack = []
      @declaration_kinds = []
      @module_name_stack = []
      @in_singleton_method = false
      @current_method = nil
      @current_def = nil
      @lexical_names = []
      @class_body_defs = []
      @class_singleton_defs = []
    end

    # A module declaration does not push a name — `@class_name_stack` is about
    # the enclosing CLASS — but it does decide what `self` is inside it.
    def visit_module_node(node)
      @declaration_kinds.push(:module)
      @module_name_stack.push(module_name_for(node))
      @lexical_names.push(lexical_name_for(node))
      super
    ensure
      @declaration_kinds.pop
      @module_name_stack.pop
      @lexical_names.pop
    end

    def lexical_name_for(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path) or return @lexical_names.last
      outer = @lexical_names.last

      outer ? "#{outer}::#{segment}" : segment
    end

    # A module's FQN, joined with whatever encloses it. Tracked apart from
    # `@class_name_stack`, which modules deliberately stay out of — a module
    # name is not a `self` type, and the only thing this answers is WHICH module
    # the annotators' answer was about (felixefelip/rbs_infer#161).
    def module_name_for(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path) or return nil
      outer = @module_name_stack.last || @class_name_stack.last

      outer ? "#{outer}::#{segment}" : segment
    end

    def visit_class_node(node)
      @declaration_kinds.push(:class)
      @assigned_types.from_class(node, into: @local_var_types)

      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      full_name =
        if segment
          @class_name_stack.empty? ? segment : "#{@class_name_stack.last}::#{segment}"
        end
      @class_name_stack.push(full_name) if full_name
      @lexical_names.push(lexical_name_for(node))
      @class_body_defs.push(InheritedReach.body_defs(node, :instance).to_set)
      @class_singleton_defs.push(InheritedReach.body_defs(node, :singleton).to_set)
      super
      @class_body_defs.pop
      @class_singleton_defs.pop
      @lexical_names.pop
      @class_name_stack.pop if full_name
      @declaration_kinds.pop
    end

    def visit_def_node(node)
      old_vars = @local_var_types.dup
      old_singleton = @in_singleton_method
      old_method = @current_method
      # `def self.foo` carries a receiver; plain `def foo` does not.
      @in_singleton_method = !node.receiver.nil?
      @current_method = node.name.to_s
      old_def = @current_def
      @current_def = node
      old_params = @current_def_params
      @current_def_params = positional_param_names(node)
      unless @method_scoped_var_names.empty?
        @local_var_types = @local_var_types.reject { |name, _| @method_scoped_var_names.include?(name) }
        @local_var_types.merge!(@local_var_types_by_method[@current_method] || {})
      end
      @assigned_types.from_def(node, into: @local_var_types)
      super
      @current_def_params = old_params
      @current_def = old_def
      @current_method = old_method
      @in_singleton_method = old_singleton
      @local_var_types = old_vars
    end

    def visit_super_node(node)
      if super_reaches_target_initialize?
        args = @arguments.for_initialize(node)
        @usages << args unless args.empty?
      elsif super_reaches_target_method?
        read_super_as_call(node, @current_method)
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

    def positional_param_names(node)
      params = node.parameters or return []

      (params.requireds + params.optionals).filter_map { |p| p.name.to_s if p.respond_to?(:name) }
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

        saved = @local_var_types.dup
        ivars.each { |name, type| @local_var_types[name] = type }
        clause.statements&.accept(self)
        @local_var_types = saved
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
          receiver_type = resolve_receiver_type(node.receiver)
          @receivers.keys_by_branch(receiver_type, method_name, namespace: lexical_class_name).each do |key, branches|
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

          receiver_type = resolve_receiver_type(node.receiver)
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
      @receivers.match_class?(name, namespace: lexical_class_name)
    end

    def lexical_class_name
      @class_name_stack.last || @caller_class_name
    end

    def block_receiver_matches?(node)
      receiver_type = resolve_receiver_type(node.receiver)
      receiver_type && match_class?(receiver_type)
    end

    # Lookup the type of an `:ivar` reference. Tries the `@`-prefixed
    # key first (the convention used by `ErbCallerResolver` to keep
    # ivar names separate from same-basename local vars), then falls
    # back to the unprefixed key (used by `AssignedTypes#from_class`
    # for in-class ivars).
    def lookup_ivar_type(node)
      full = node.name.to_s
      @local_var_types[full] || @local_var_types[full.sub(/\A@/, "")] || declared_ivar_type(full)
    end

    def declared_ivar_type(name)
      return nil unless @method_type_resolver

      class_name = lexical_class_name or return nil

      type = @method_type_resolver.resolve_ivar_types(class_name)[name]
      type if type && type != "untyped"
    end

    def apply_established_ivars(node)
      return if @established_ivars_by_method.empty?
      return unless node.receiver.nil?

      established = @established_ivars_by_method[node.name.to_s] or return
      established.each { |ivar, type| @local_var_types[ivar] = type }
    end

    # `{ literal_key => ivars }` for the partitions keyed on this `case`'s subject, or `{}`.
    # Only a bare read of a METHOD PARAMETER qualifies: the correlation is between the
    # caller's argument and the branch, and a `case` on anything else says nothing about
    # what the caller passed.
    def partitions_for_case(node)
      return {} if @argument_partitions_by_method.empty?
      return {} unless @current_method

      predicate = node.predicate
      return {} unless predicate.is_a?(Prism::LocalVariableReadNode)

      param = predicate.name.to_s
      (@argument_partitions_by_method[@current_method] || []).each_with_object({}) do |partition, acc|
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
      previous = @self_condition
      @self_condition = self_condition(node, branches)
      @arguments.for_params(node, @target_methods[method_name])
    ensure
      @self_condition = previous
    end

    # `[parameter index, branch]`, or nil when the pairing cannot be stated.
    def self_condition(node, branches)
      return nil unless branches.size == 1
      return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)

      index = @current_def_params.index(node.receiver.name.to_s) or return nil
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
      else resolve_receiver_type(receiver).to_s.start_with?("singleton(")
      end
    end

    # `Kid.new(...)` where the `initialize` `Kid` runs is the target's: an
    # inherited one is a call site whatever the receiver is called
    # (felixefelip/rbs_infer#412).
    def constructs_target?(receiver)
      return false if @inherited_initializers.constructs.empty?
      return false unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      resolved = resolve_constant_arg_type(receiver)[/\Asingleton\((.+)\)\z/, 1] or return false
      @inherited_initializers.constructs.include?(resolved.delete_prefix("::"))
    end

    # A `super` written in an `initialize` of a class's own body, in a class
    # whose `super` reaches the target's.
    def super_reaches_target_initialize?
      return false if @inherited_initializers.supers.empty?
      return false unless @current_method == "initialize" && own_method_side == :instance

      @inherited_initializers.supers.include?(@lexical_names.last)
    end

    # The same for any other target method, on either side: a `super` in the
    # class's own method of that name, in a class whose `super` reaches the
    # target's.
    def super_reaches_target_method?
      return false if @inherited_supers.empty?

      side = own_method_side or return false
      classes = @inherited_supers.dig(side, @current_method) or return false
      classes.include?(@lexical_names.last)
    end

    # Which side of the enclosing class's own body the current method is
    # written on (`InheritedReach.body_defs`): `:instance`, `:singleton` for a
    # `def self.` or a `def` in its `class << self`, or nil for one in a block
    # (`Class.new(Other) do`) or inside another method, which belongs to some
    # other chain.
    def own_method_side
      return nil unless @declaration_kinds.last == :class

      if @class_body_defs.last&.include?(@current_def)
        :instance
      elsif @class_singleton_defs.last&.include?(@current_def)
        :singleton
      end
    end

    # Steep's type for this particular read, or nil. Prism's character column
    # matches Parser's; the byte column would drift on multibyte source.
    def lvar_read_type(node)
      @local_var_read_types[[node.location.start_line, node.location.start_character_column]]
    end

    def resolve_value_type(node) # rubocop:todo Metrics/MethodLength
      # A hash literal is handled here, ahead of the generic literal inferrer, so its VALUES
      # resolve with what this collector knows — ivars, locals, method returns. The generic
      # inferrer builds the same record shape but sees none of that, so `{ post: @post }`
      # came out `{ post: untyped }` even where `@post` is a known `Post & Post::Validated`.
      return @arguments.hash_literal_type(node) if @arguments.record_shaped?(node)

      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, constant_resolver: @constant_arg_resolver)
      return literal if literal

      case node
      when Prism::LocalVariableReadNode
        lvar_read_type(node) || @local_var_types[node.name.to_s] || "untyped"
      when Prism::InstanceVariableReadNode
        lookup_ivar_type(node) || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          refined_self_method_type(node.name.to_s) || @method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          resolve_method_chain(node) || "untyped"
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        resolve_constant_arg_type(node)
      when Prism::SelfNode
        current_self_type
      when Prism::ImplicitNode
        resolve_value_type(node.value)
      else
        "untyped"
      end
    end

    # See ConstantArgTypeResolver (#46).
    def resolve_constant_arg_type(node)
      name = RbsInfer::Analyzer.extract_constant_path(node)
      @constant_arg_resolver.resolve(name: name, namespace: lexical_class_name) || "untyped"
    end

    # Resolve `self` (passed as an argument or used as a receiver) to the
    # lexically-enclosing class. Inside an instance method `self` is an
    # instance of that class (`Caderneta`); inside a singleton method
    # (`def self.x`) it's the class object itself (`singleton(Caderneta)`),
    # so we never infer a bogus instance type for it. Falls back to the
    # caller class (derived from the file path) when no class node is on
    # the stack, and to `"untyped"` when even that is unknown.
    #
    # Drives call-site inference like `Cadastrar.new(self)` inside
    # `Caderneta#criar_caderneta_de_vacinacao`, where the positional
    # `initialize(caderneta)` param should infer as `Caderneta`.
    def current_self_type
      # Inside an instance method covered by an after-validation callback,
      # `self` is the validated record — prefer the refined type from the
      # callback sidecar (e.g. `Caderneta & Caderneta::Validated`) over the
      # bare lexical class. Singleton methods aren't callback handlers, so
      # they keep the lexical resolution.
      unless @in_singleton_method
        refined = @current_method && @self_types_by_method[@current_method]
        return refined if refined && !refined.empty?
      end

      # Inside a module, an INSTANCE method's `self` is whatever includes it.
      # Unknowable from the nesting — claiming the module is a lie that reaches
      # the signature (`Token.authenticate(self, …)` typed its parameter
      # `ActionController::HttpAuthentication`, which has no `request`) — but
      # not unknowable in general: the self-type annotators answer it for a
      # covered concern, and that answer is the one the call site should see.
      # `Card::Entropy.for(self)` needs the `Card` half of `Card & Card::Entropic`
      # for `last_active_at`. Only for the module the file is named after, so a
      # sibling module in the same file cannot borrow it.
      # A `def self.x` in a module is different: there `self` IS the module.
      return module_self_type || "untyped" if !@in_singleton_method && @declaration_kinds.last == :module

      base = lexical_class_name or return "untyped"

      @in_singleton_method ? "singleton(#{base})" : base
    end

    # The answer for the module being visited. An unnameable one (a dynamic
    # constant path) falls back to the name the file stands for.
    #
    # Narrowed to the hosts that actually call THIS method. The annotators state
    # what `self` may be across the whole module — every class that includes it,
    # every one that extends it — and that is the right answer for a
    # declaration. As the type of an ARGUMENT it is too wide: `Foo#bazinga` is
    # invoked from `Bar`'s body and nowhere else, so the `self` it passes on is
    # `singleton(Bar)`, not the union with `Baz` (felixefelip/rbs_infer#222).
    def module_self_type
      declared = @module_self_types[@module_name_stack.last || @caller_class_name]
      return declared if declared.nil? || @current_method.nil?

      @invoker_self_types.narrow(method_name: @current_method, declared: declared, given: @self_condition)
    end

    # Resolves a `self.<method>` against the refined `self` type when the
    # enclosing method is covered by an after-validation callback (its `self`
    # is `Model & Model::Validated`). This makes `self.<association>` resolve
    # to the marker-decorated reader (e.g. `Caderneta & Caderneta::Validated`)
    # rather than the base nilable reader. Returns nil outside such methods,
    # so the normal `@method_return_types` path is preserved unchanged.
    def refined_self_method_type(method_name)
      return nil if @in_singleton_method
      return nil unless @method_type_resolver

      refined = @current_method && @self_types_by_method[@current_method]
      return nil if refined.nil? || refined.empty?

      resolved = @method_type_resolver.resolve(refined, method_name, arg_types: nil)
      resolved if resolved && resolved != "untyped"
    end

    # Resolver receiver.method() → tipo do retorno do method no receiver
    def resolve_method_chain(node)
      return nil unless @method_type_resolver

      # Constant receiver → singleton lookup (`Account.first`), not
      # instance. `self` in a class method's RBS is the class itself
      # (same convention as Analyzer#infer_attr_types_from_initialize).
      if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
        class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
        return nil unless class_name

        resolved = @method_type_resolver.resolve_class_method(class_name, node.name.to_s)
        return resolved == "self" ? class_name : resolved
      end

      receiver_type = resolve_receiver_type(node.receiver)
      return nil unless receiver_type && receiver_type != "untyped"

      resolved = @method_type_resolver.resolve(receiver_type, node.name.to_s, arg_types: nil)
      # `a&.b` with a nilable receiver: the nil flows into the result (on
      # a plain call the resolve is optimistic — `a.b` raises on nil).
      if resolved && node.safe_navigation? && receiver_type.end_with?("?")
        resolved = RbsInfer::Signatures::RbsParserUtil.nilablize(resolved)
      end
      resolved
    end

    # Resolver o tipo do receiver de um method call
    def resolve_receiver_type(node)
      case node
      when Prism::LocalVariableReadNode
        @local_var_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        lookup_ivar_type(node)
      when Prism::CallNode
        if node.receiver.nil?
          # Implicit `self.<method>` (ex: attr_reader/association). Inside a
          # callback-refined method, resolve against the refined self so a
          # `self.<association>` picks up the marker-decorated reader instead
          # of the base nilable one.
          refined_self_method_type(node.name.to_s) || @method_return_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        else
          resolve_method_chain(node)
        end
      when Prism::SelfNode
        # self → tipo da classe léxica (instância ou singleton); nil quando
        # desconhecido, mantendo a convenção nil-returning deste método.
        resolved = current_self_type
        resolved == "untyped" ? nil : resolved
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # Constant receiver → singleton method call on the class
        # (`Current.user = x`, `Notifier.notify(...)`). The class name is
        # itself the receiver's "type" for match_class? purposes
        # (felixefelip/rbs_infer#19).
        RbsInfer::Analyzer.extract_constant_path(node)
      end
    end
  end
end
