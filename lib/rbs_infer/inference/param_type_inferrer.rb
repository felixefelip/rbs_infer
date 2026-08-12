module RbsInfer::Inference
  # What a method's parameters accept — from the intra-class calls, from the
  # wrappers that forward arguments on, and from the call sites in other files.
  #
  # The three kinds of evidence answer the SAME question and cross: a method
  # called with `String` in one file and `:symbol` in another has both types, not
  # whichever was seen first. So the union lives here rather than in the caller —
  # the Analyzer asks once and gets the whole answer (felixefelip/rbs_infer#64).
  #
  # `initialize` gets its own method because its evidence is a different thing
  # entirely: the project's `.new`s, not calls to the method.
  class ParamTypeInferrer
    ITERATOR_METHODS = RbsInfer::ITERATOR_METHODS

    # What the blocks passed at the cross-class call sites return, picked up in
    # passing by `infer_method_param_types` — this is the pipeline's only sweep
    # over caller files, and `BlockSignatureResolver` needs the answer later
    # (felixefelip/rbs_infer#155). Read, not injected: it used to be an Analyzer
    # ivar written by one pass and consumed 400 lines further down, with nothing
    # saying the two were connected.
    attr_reader :caller_block_returns

    # `source_index`, `mixin_index` and `extra_caller_sources` decide WHICH files
    # are swept for call sites, so none of them is defaulted: a caller that forgets
    # one does not break — it infers from a smaller set of callers and emits
    # `untyped` where there was an answer (docs/engineering/required-threaded-deps.md).
    # `extra_caller_sources` may legitimately be nil (not every project registers
    # one), but saying so is the caller's job.
    def initialize(target_file:, target_class:, source_files:, source_index:, method_type_resolver:, type_merger:,
                   mixin_index:, extra_caller_sources:, steep_bridge: nil, parse_cache: nil, file_index: nil,
                   caller_file_cache: nil)
      @target_file = target_file
      @target_class = target_class
      @source_files = source_files
      @source_index = source_index
      @method_type_resolver = method_type_resolver
      @type_merger = type_merger
      @mixin_index = mixin_index
      @extra_caller_sources = extra_caller_sources
      @steep_bridge = steep_bridge
      @parse_cache = parse_cache || RbsInfer::Project::ParseCache.new
      @file_index = file_index || RbsInfer::Project::FileIndex.new(source_files)
      @caller_file_cache = caller_file_cache || RbsInfer::Project::CallerFileCache.new(@parse_cache)
      # Env-only default; refined per caller file in
      # infer_wrapper_method_param_types (#46).
      @constant_arg_resolver = ConstantArgTypeResolver.new(steep_bridge: @steep_bridge, caller_constant_types: {})
      @constant_namespace = nil
      @caller_block_returns = nil
    end

    # `{ "notify" => { "user" => "User", "message" => "String" } }` — every kind
    # of evidence, already crossed.
    #
    # `is_module` comes per call rather than from the constructor: what settles it
    # is the target's parse, which happens after this object exists.
    def infer_method_param_types(members, attr_types, parsed_target:, is_module:)
      inferred = infer_from_intra_class(attr_types, parsed_target)

      infer_from_callers(members, parsed_target: parsed_target, is_module: is_module).each do |method_name, param_types|
        inferred[method_name] ||= {}
        param_types.each do |param_name, type|
          existing = inferred[method_name][param_name]
          inferred[method_name][param_name] =
            if existing && existing != "untyped"
              TypeMerger.union_types([existing, type])
            else
              type
            end
        end
      end

      nilablize_nil_defaults(members, inferred)
      inferred
    end

    # What `initialize` accepts, from the project's `.new`s — with two fallbacks,
    # in order of evidence: the signature RBS already declares, and the wrappers
    # that forward arguments into a `.new` no direct call site reaches.
    def infer_initialize_types(parsed_target:)
      usages = find_new_calls(parsed_target)
      return {} if usages.empty?

      merged = @type_merger.merge_argument_types(usages)

      if merged.values.all? { |t| t == "untyped" }
        fallback = @method_type_resolver.resolve_init_param_types(@target_class)
        merged = fallback unless fallback.empty?
      end

      if merged.values.all? { |t| t == "untyped" }
        infer_init_types_via_forwarding_wrappers.each { |k, v| merged[k] = v if merged[k] == "untyped" }
      end

      merged
    end

    private

    def infer_from_intra_class(attr_types, parsed_target)
      return {} unless parsed_target

      # Pré-coletar parâmetros posicionais de todos os métodos
      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)
      positional_params = {}
      collector.defs.each do |defn|
        next unless defn.is_a?(Prism::DefNode) && defn.parameters
        names = []
        defn.parameters.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if defn.parameters.respond_to?(:requireds)
        defn.parameters.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if defn.parameters.respond_to?(:optionals)
        rest = RestParamMarker.name_from(defn.parameters)
        names << RestParamMarker.mark(rest) if rest
        positional_params[defn.name.to_s] = names unless names.empty?
      end

      visitor = IntraClassCallAnalyzer.new(
        attr_types: attr_types,
        method_type_resolver: @method_type_resolver,
        method_positional_params: positional_params,
        steep_bridge: @steep_bridge,
        source_code: parsed_target.source
      )
      parsed_target.tree.accept(visitor)
      inferred = visitor.inferred_param_types.dup

      # Forwarding: detectar métodos que chamam Klass.new(param:, param:)
      # com parâmetros forwarded, e inferir tipos via call-sites do método wrapper
      forwarding = detect_forwarding_methods(parsed_target.result)
      forwarding.each do |method_name, param_names|
        # Pular se já temos tipos inferidos (não-untyped) para este método
        if inferred[method_name]
          next unless inferred[method_name].values.all? { |t| t == "untyped" }
        end

        types = infer_wrapper_method_param_types(method_name, param_names)
        next if types.empty? || types.values.all? { |t| t == "untyped" }

        inferred[method_name] ||= {}
        types.each { |k, v| inferred[method_name][k] = v }
      end

      inferred
    end

    # ─── Call sites in other files ─────────────────────────────────────

    # `PostPublisher` calls `notifier.notify(post.user, "msg")` → `user: User`,
    # `message: String`.
    def infer_from_callers(members, parsed_target:, is_module:)
      # `attr_writer_methods` are SYNTHETIC writers standing in for
      # `attr_accessor`-generated methods, and name their param after the attr
      # (`user`). A real `def user=(value)` overriding that attr names it `value`,
      # and the def is the authority: the inferred type is keyed by param name, and
      # RbsBuilder substitutes it by matching that name in the signature. Letting
      # the synthetic name win filed the type under `user` while the signature said
      # `value`, so the substitution missed and the param stayed `untyped` even
      # though the call-site had been read correctly.
      target_methods = attr_writer_methods(members).merge(target_method_params(parsed_target))
      return {} if target_methods.empty?

      analyzer = CallerFileAnalyzer.new(
        target_class: @target_class,
        target_file: @target_file,
        method_type_resolver: @method_type_resolver,
        init_positional_params: init_positional_params(parsed_target),
        target_methods: target_methods,
        steep_bridge: @steep_bridge,
        # felixefelip/rbs_infer#155: the methods whose block return is still open
        # — the ones worth collecting call-site blocks for.
        block_methods: members.select { |m| BlockSignatureResolver.untyped_block_return?(m) }.map(&:name).to_set,
        method_owners: nested_method_owners(members),
        mixin_index: @mixin_index
      )

      caller_files(target_methods, is_module: is_module) do |file, force_bare|
        analyzer.analyze(file, force_bare: force_bare)
      end

      @extra_caller_sources&.call(analyzer, @target_class, @source_files)
      @caller_block_returns = analyzer.method_block_returns

      result = {}
      analyzer.method_call_usages.each do |method_name, usages|
        merged = @type_merger.merge_argument_types(usages)
        merged.reject! { |_, t| t == "untyped" }
        result[method_name] = merged unless merged.empty?
      end
      result
    end

    # Who may be calling the target, by four routes no single index covers. Yields
    # each file along with whether it matches RECEIVERLESS calls — which only the
    # two routes that proved reachability earn.
    def caller_files(target_methods, is_module:)
      referencing = @source_index.files_referencing(@target_class)

      # A concern's instance methods are called *bare* by includer hosts and by
      # the host's sibling concerns — files that never name the concern, so the
      # constant-reference index misses them. For a module target, fold in the
      # mixin graph and force bare-call matching on those files (#64).
      reaching = is_module ? @mixin_index.files_reaching(@target_class).to_set : Set.new

      # A caller that reaches the target through a VALUE — an ivar, a local, a
      # `Current.<attr>` — never spells the class name, so the constant index above
      # does not return it. Add the files that call one of the target's own methods
      # on some receiver; `match_class?` still has to prove that receiver is the
      # target before the call site is used (felixefelip/rbs_infer#131).
      calling = target_methods.keys.flat_map { |m| @source_index.files_calling(m) }.to_set

      # A target the ancestor graph puts behind EVERY object is called receiverlessly
      # from anywhere: `include Foo` in a class body is `Module#include` on the class
      # object. Such a call site names neither the target nor a receiver, so all three
      # indexes above miss it — `files_calling` keys on the `.`, and the mixin graph
      # only ever hears about a module some source actually includes. Ask instead which
      # files make a bare call to one of the target's own methods, and let them match
      # bare like the mixin-graph files do.
      bare_reaching =
        if @steep_bridge&.universal_ancestor?(@target_class)
          target_methods.keys.flat_map { |m| @source_index.files_with_bare_call(m) }.to_set
        else
          Set.new
        end

      (referencing.to_set | reaching | calling | bare_reaching).each do |file|
        yield file, reaching.include?(file) || bare_reaching.include?(file)
      end
    end

    # The target's `.new`s, in every file that names it.
    def find_new_calls(parsed_target)
      analyzer = CallerFileAnalyzer.new(
        target_class: @target_class,
        method_type_resolver: @method_type_resolver,
        target_file: @target_file,
        init_positional_params: init_positional_params(parsed_target),
        target_methods: target_method_params(parsed_target),
        steep_bridge: @steep_bridge,
        mixin_index: @mixin_index
      )
      @source_index.files_referencing(@target_class).flat_map { |file| analyzer.analyze(file) }
    end

    # ─── What the target declares, for matching the call sites ─────────

    # The parameter names of each target-class method:
    # `{ "notify" => ["user", "message"] }`.
    #
    # Keywords come AFTER positionals: `extract_cross_class_args` maps
    # positional args by index (which can only reach the requireds+optionals
    # prefix) and kwargs by name, so the order preserves the positional mapping.
    #
    # A rest param sits between the two, where its index is, marked by
    # `RestParamMarker` — see there for what the marker is and why it travels
    # in the list itself.
    def target_method_params(parsed_target)
      return {} unless parsed_target

      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)

      methods = {}
      collector.defs.each do |defn|
        next if defn.name == :initialize
        params = defn.parameters
        next unless params

        names = []
        params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
        params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
        rest = RestParamMarker.name_from(params)
        names << RestParamMarker.mark(rest) if rest
        params.keywords.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:keywords)
        methods[defn.name.to_s] = names unless names.empty?
      end
      methods
    end

    # The positional parameter names of the target's `initialize`.
    def init_positional_params(parsed_target)
      return [] unless parsed_target

      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)

      init_def = collector.defs.find { |d| d.name == :initialize }
      return [] unless init_def&.parameters

      params = init_def.parameters
      names = []
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
      params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
      rest = RestParamMarker.name_from(params)
      names << RestParamMarker.mark(rest) if rest
      names
    end

    # `attr_accessor`/`attr_writer :x` defines an `x=` method, so an external
    # `receiver.x = value` is just a call to it. Expose those writers as
    # synthetic target methods (single param named after the attr) so the
    # cross-class call-site inference types the assigned value exactly like
    # any other method argument (felixefelip/rbs_infer#71).
    def attr_writer_methods(members)
      members.each_with_object({}) do |m, acc|
        next unless [:attr_accessor, :attr_writer].include?(m.kind)
        acc["#{m.name}="] = [m.name]
      end
    end

    # `{ "deny" => [["Example19::Responder", :class_method]] }` for the target's
    # methods that live in a nested MODULE. Such a module is emitted inside the
    # target's block rather than as a target of its own
    # (felixefelip/rbs_infer#22), so its call sites were matched against the
    # wrong name and its parameters stayed `untyped`
    # (felixefelip/rbs_infer#159).
    #
    # EVERY owner of the name, with its kind — not the first one. Under a
    # namespace wrapper the members of every nested module land in the same
    # table, and a name two of them declare is the normal case, not the exotic
    # one: `Example23` holds `Foo#bazingado` and `Baz.bazingado`. Keeping only
    # the first left `Foo` answering for a call the singleton makes, so the
    # matcher compared the receiver against the wrong owner and dropped the call
    # site (felixefelip/rbs_infer#215).
    def nested_method_owners(members)
      members.each_with_object({}) do |member, owners|
        next unless [:method, :class_method].include?(member.kind)
        next if member.owner.nil? || member.owner.empty?

        entry = [RbsInfer::Inference::MethodKey.qualify_owner(@target_class, member.owner), member.kind]
        entries = (owners[member.name] ||= [])
        entries << entry unless entries.include?(entry)
      end
    end

    # A param whose default is the literal `nil` accepts nil however many non-nil
    # arguments the call sites passed — the default is the call site nobody writes
    # (felixefelip/rbs_infer#208). Applied after the union, and only once a type is
    # there to widen: while the parameter is `untyped` the nil is already admitted,
    # and `untyped?` is not a spelling.
    def nilablize_nil_defaults(members, inferred)
      members.each do |member|
        next unless [:method, :class_method].include?(member.kind)
        next if member.param_nil_defaults.nil? || member.param_nil_defaults.empty?

        types = RbsInfer::Inference::MethodKey.lookup(
          inferred,
          member.name,
          owner: RbsInfer::Inference::MethodKey.qualify_owner(@target_class, member.owner),
          kind: member.kind
        ) or next
        member.param_nil_defaults.each do |param_name|
          current = types[param_name]
          next if current.nil? || current == "untyped"

          types[param_name] = RbsInfer::Signatures::RbsParserUtil.nilablize(current)
        end
      end
    end

    # Rastreia métodos em OUTROS arquivos que chamam TargetClass.new(param:)
    # com parâmetros forwarded, e resolve os tipos via call-sites desses wrappers
    def infer_init_types_via_forwarding_wrappers
      types = {}
      short_name = @target_class.split("::").last

      files = @source_index.files_referencing(@target_class)
      files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry
        next unless entry.source.include?(short_name)

        forwarding = detect_forwarding_methods(entry.result, target_class_filter: @target_class)
        next if forwarding.empty?

        forwarding.each do |method_name, param_names|
          wrapper_types = infer_wrapper_method_param_types(method_name, param_names)
          wrapper_types.each { |k, v| types[k] = v if v != "untyped" }
        end
      end

      types
    end

    # Detecta métodos que fazem Klass.new(param:, param:) com parâmetros forwarded
    def detect_forwarding_methods(parse_result, target_class_filter: nil)
      forwarding = {}
      collector = RbsInfer::AST::DefCollector.new
      parse_result.value.accept(collector)

      collector.defs.each do |defn|
        next unless defn.parameters.is_a?(Prism::ParametersNode)

        param_names = Set.new
        defn.parameters.keywords.each { |kw| param_names << kw.name.to_s.chomp(":") } if defn.parameters.respond_to?(:keywords)
        defn.parameters.requireds.each { |p| param_names << p.name.to_s } if defn.parameters.respond_to?(:requireds)
        next if param_names.empty?

        # Procurar chamadas .new no corpo com args que são params forwarded
        body = defn.body
        next unless body

        new_calls = RbsInfer::Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::CallNode) && n.name == :new && n.receiver && n.arguments }
        new_calls.each do |node|
          if target_class_filter
            receiver_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
            next unless receiver_name
            normalized = receiver_name.sub(/\A::/, "")
            target = target_class_filter.sub(/\A::/, "")
            next unless normalized == target || target.end_with?("::#{normalized}")
          end

          forwarded_params = extract_forwarded_keyword_params(node, param_names)
          next if forwarded_params.empty?

          forwarding[defn.name.to_s] = forwarded_params
        end
      end

      forwarding
    end

    # Extrai nomes de keyword args que são forwarded de parâmetros do método
    def extract_forwarded_keyword_params(call_node, method_param_names)
      forwarded = Set.new
      call_node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)

        arg.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)

          key = elem.key
          key_name = key.is_a?(Prism::SymbolNode) ? key.unescaped : nil
          next unless key_name

          value = elem.value
          value = value.value if value.is_a?(Prism::ImplicitNode)
          if value.is_a?(Prism::LocalVariableReadNode) && method_param_names.include?(value.name.to_s)
            forwarded << value.name.to_s
          end
        end
      end
      forwarded
    end

    # Infere tipos dos parâmetros de um método via seus call-sites nos source_files
    def infer_wrapper_method_param_types(method_name, param_names)
      usages = []

      @source_files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry
        next unless entry.source.include?(method_name)

        analysis = @caller_file_cache.get(file)
        next unless analysis

        file_result = entry.result

        # Resolver scoped to this caller file's own constants (#46).
        @constant_arg_resolver = ConstantArgTypeResolver.new(
          steep_bridge: @steep_bridge,
          caller_constant_types: @steep_bridge ? @steep_bridge.constant_types(entry.source) : {}
        )
        @constant_namespace = analysis.class_name

        # Montar method_return_types do caller a partir dos membros já coletados
        method_return_types = {}
        analysis.members.each do |m|
          case m.kind
          when :method
            if m.signature =~ /.*->\s*(.+)$/
              method_return_types[m.name] = $1.strip
            end
          when :attr_accessor, :attr_reader
            if m.signature =~ /\w+:\s*(.+)/
              type = $1.strip
              method_return_types[m.name] ||= type unless type == "untyped"
            end
          end
        end

        if analysis.class_name
          caller_types = @method_type_resolver.resolve_all(analysis.class_name)
          caller_types.each { |name, type| method_return_types[name] ||= type }
        end

        # Procurar chamadas ao método e extrair tipos dos keyword args
        matching_calls = RbsInfer::Analyzer.find_all_nodes(file_result.value) { |n| n.is_a?(Prism::CallNode) && n.name == method_name.to_sym && n.arguments }
        matching_calls.each do |node|

          local_var_types = collect_local_var_types_for_scope(node, file_result, method_return_types, analysis.class_name, source_code: entry.source)

          usage = {}
          node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |elem|
              next unless elem.is_a?(Prism::AssocNode)
              key = elem.key
              key_name = key.is_a?(Prism::SymbolNode) ? key.unescaped : nil
              next unless key_name && param_names.include?(key_name)

              value = elem.value
              value = value.value if value.is_a?(Prism::ImplicitNode)
              type = resolve_arg_value_type(value, local_var_types, method_return_types)
              usage[key_name] = type
            end
          end
          usages << usage unless usage.empty?
        end
      end

      @type_merger.merge_argument_types(usages)
    end

    # Resolve o tipo de um valor de argumento
    def resolve_arg_value_type(node, local_var_types, method_return_types)
      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, constant_resolver: @constant_arg_resolver, context_class: @constant_namespace)
      return literal if literal

      case node
      when Prism::LocalVariableReadNode
        local_var_types[node.name.to_s] || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          # receiver.method → tentar resolver
          receiver_type = resolve_arg_value_type(node.receiver, local_var_types, method_return_types)
          if receiver_type && receiver_type != "untyped"
            @method_type_resolver.resolve(receiver_type, node.name.to_s) || "untyped"
          else
            "untyped"
          end
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        name = RbsInfer::Analyzer.extract_constant_path(node)
        @constant_arg_resolver.resolve(name: name, namespace: @constant_namespace) || "untyped"
      when Prism::ImplicitNode
        resolve_arg_value_type(node.value, local_var_types, method_return_types)
      else
        "untyped"
      end
    end

    # Coleta tipos de variáveis locais no escopo do nó
    def collect_local_var_types_for_scope(target_node, parse_result, method_return_types, caller_class_name, source_code: nil)
      local_var_types = {}

      # Encontrar o def encapsulante
      collector = RbsInfer::AST::DefCollector.new
      parse_result.value.accept(collector)

      enclosing_def = collector.defs.find do |defn|
        defn.location.start_offset <= target_node.location.start_offset &&
          defn.location.end_offset >= target_node.location.end_offset
      end

      return local_var_types unless enclosing_def

      # Use Steep to resolve local var types in the caller file
      if @steep_bridge && source_code
        method_name = enclosing_def.name.to_s
        steep_vars = @steep_bridge.local_var_types_per_method(source_code)
        steep_method_vars = steep_vars[method_name]
        local_var_types.merge!(steep_method_vars) if steep_method_vars
      end

      # Resolver tipos de params do método encapsulante via call-sites do caller class
      if caller_class_name
        init_params = @method_type_resolver.resolve_init_param_types(caller_class_name)
        params = enclosing_def.parameters
        if params
          params.keywords.each { |kw| name = kw.name.to_s.chomp(":"); local_var_types[name] = init_params[name] if init_params[name] } if params.respond_to?(:keywords)
          params.requireds.each { |p| name = p.name.to_s; local_var_types[name] = init_params[name] if init_params[name] } if params.respond_to?(:requireds)
        end
      end

      # Coletar assignments locais (em qualquer profundidade, antes do target_node)
      all_assignments = RbsInfer::Analyzer.find_all_nodes(enclosing_def) do |n|
        n.is_a?(Prism::LocalVariableWriteNode) &&
          n.location.start_offset < target_node.location.start_offset
      end

      # Pass 1: resolver assignments (pode não resolver os que dependem de block params)
      resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)

      # Resolver tipos de parâmetros de blocos (collection.each do |item|)
      resolve_block_param_types(enclosing_def, target_node, local_var_types, method_return_types)

      # Pass 2: re-resolver assignments que agora dependem de block params
      resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)

      local_var_types
    end

    # Resolve tipos de assignments locais
    def resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)
      all_assignments.each do |assign|
        var_name = assign.name.to_s
        next if local_var_types[var_name] && local_var_types[var_name] != "untyped"

        if assign.value.is_a?(Prism::CallNode)
          if assign.value.receiver.nil?
            method_name = assign.value.name.to_s
            local_var_types[var_name] = method_return_types[method_name] if method_return_types[method_name]
          elsif assign.value.name == :new && assign.value.receiver
            class_name = RbsInfer::Analyzer.extract_constant_path(assign.value.receiver)
            if class_name
              local_var_types[var_name] = resolve_constant_in_namespace(class_name, caller_class_name)
            end
          else
            # receiver.method → tentar resolver tipo
            class_name = RbsInfer::Analyzer.extract_constant_path(assign.value.receiver)
            if class_name
              resolved = @method_type_resolver.resolve_class_method(class_name, assign.value.name.to_s)
              if resolved && resolved != "untyped"
                local_var_types[var_name] = resolve_constant_in_namespace(resolved, caller_class_name)
              end
            else
              receiver_type = resolve_arg_value_type(assign.value.receiver, local_var_types, method_return_types)
              if receiver_type && receiver_type != "untyped"
                resolved = @method_type_resolver.resolve(receiver_type, assign.value.name.to_s)
                local_var_types[var_name] = resolved if resolved && resolved != "untyped"
              end
            end
          end
        end
      end
    end

    # Resolve tipos de parâmetros de blocos iteradores (collection.each do |item|)
    def resolve_block_param_types(enclosing_def, target_node, local_var_types, method_return_types)
      block_calls = RbsInfer::Analyzer.find_all_nodes(enclosing_def) do |n|
        n.is_a?(Prism::CallNode) && n.block.is_a?(Prism::BlockNode) &&
          ITERATOR_METHODS.include?(n.name) &&
          n.block.location.start_offset <= target_node.location.start_offset &&
          n.block.location.end_offset >= target_node.location.end_offset
      end

      block_calls.each do |call|
        block = call.block
        next unless block.parameters.is_a?(Prism::BlockParametersNode)
        next unless block.parameters.parameters

        block_param_names = []
        block.parameters.parameters.requireds&.each do |p|
          block_param_names << p.name.to_s if p.respond_to?(:name)
        end
        next if block_param_names.empty?

        # Resolver tipo da coleção (receiver do .each, .map, etc.)
        next unless call.receiver
        collection_type = resolve_arg_value_type(call.receiver, local_var_types, method_return_types)
        next if collection_type.nil? || collection_type == "untyped"

        # Extrair tipo do elemento da coleção
        element_type = extract_element_type(collection_type)
        next unless element_type

        # Primeiro block param recebe o tipo do elemento
        local_var_types[block_param_names.first] = element_type
      end
    end

    # Extrai o tipo do elemento de uma coleção via RBS definitions
    def extract_element_type(collection_type)
      rbs_definition_resolver.resolve_each_element_type(collection_type)
    end

    def rbs_definition_resolver
      @rbs_definition_resolver ||= RbsInfer::Signatures::RbsDefinitionResolver.new
    end

    # Resolve nome curto de constante no namespace do caller
    def resolve_constant_in_namespace(short_name, context_class)
      return short_name if short_name.include?("::")
      return short_name unless context_class

      parts = context_class.split("::")
      while parts.any?
        parts.pop
        candidate = (parts + [short_name]).join("::")
        class_path = RbsInfer.class_name_to_path(candidate)
        return candidate if @file_index.include?(class_path)
      end

      short_name
    end
  end
end
