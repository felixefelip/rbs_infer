module RbsInfer
  # Infere tipos de parâmetros de métodos via chamadas intra-classe,
  # detecção de forwarding wrappers e call-sites cross-class.
  #
  # Extraído de Analyzer para manter responsabilidades separadas.

  class ParamTypeInferrer
    ITERATOR_METHODS = RbsInfer::ITERATOR_METHODS

    def initialize(target_file:, target_class:, source_files:, source_index: nil, method_type_resolver:, type_merger:)
      @target_file = target_file
      @target_class = target_class
      @source_files = source_files
      @source_index = source_index
      @method_type_resolver = method_type_resolver
      @type_merger = type_merger
    end

    def infer_method_param_types(attr_types, parsed_target: nil)
      return {} unless parsed_target

      # Pré-coletar parâmetros posicionais de todos os métodos
      collector = DefCollector.new
      parsed_target.tree.accept(collector)
      positional_params = {}
      collector.defs.each do |defn|
        next unless defn.is_a?(Prism::DefNode) && defn.parameters
        names = []
        defn.parameters.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if defn.parameters.respond_to?(:requireds)
        defn.parameters.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if defn.parameters.respond_to?(:optionals)
        positional_params[defn.name.to_s] = names unless names.empty?
      end

      visitor = IntraClassCallAnalyzer.new(attr_types: attr_types, method_type_resolver: @method_type_resolver, method_positional_params: positional_params)
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

    # Rastreia métodos em OUTROS arquivos que chamam TargetClass.new(param:)
    # com parâmetros forwarded, e resolve os tipos via call-sites desses wrappers
    def infer_init_types_via_forwarding_wrappers
      types = {}
      short_name = @target_class.split("::").last

      files = @source_index ? @source_index.files_referencing(@target_class) : @source_files
      files.each do |file|
        begin
          source = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        next unless source.include?(short_name)

        result = Prism.parse(source)
        forwarding = detect_forwarding_methods(result, target_class_filter: @target_class)
        next if forwarding.empty?

        forwarding.each do |method_name, param_names|
          wrapper_types = infer_wrapper_method_param_types(method_name, param_names)
          wrapper_types.each { |k, v| types[k] = v if v != "untyped" }
        end
      end

      types
    end

    private

    # Detecta métodos que fazem Klass.new(param:, param:) com parâmetros forwarded
    def detect_forwarding_methods(parse_result, target_class_filter: nil)
      forwarding = {}
      collector = DefCollector.new
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

        new_calls = Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::CallNode) && n.name == :new && n.receiver && n.arguments }
        new_calls.each do |node|
          if target_class_filter
            receiver_name = Analyzer.extract_constant_path(node.receiver)
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
        begin
          file_source = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        next unless file_source.include?(method_name)

        file_result = Prism.parse(file_source)
        comments = file_result.comments
        lines = file_source.lines

        # Montar method_return_types do caller
        method_return_types = {}
        member_collector = ClassMemberCollector.new(comments: comments, lines: lines)
        file_result.value.accept(member_collector)
        member_collector.members.each do |m|
          case m.kind
          when :method
            if m.signature =~ /->\s*(.+)$/
              method_return_types[m.name] = $1.strip
            end
          when :attr_accessor, :attr_reader
            if m.signature =~ /\w+:\s*(.+)/
              type = $1.strip
              method_return_types[m.name] ||= type unless type == "untyped"
            end
          end
        end

        # Resolver caller class types
        caller_ext = ClassNameExtractor.new
        file_result.value.accept(caller_ext)
        if caller_ext.class_name
          caller_types = @method_type_resolver.resolve_all(caller_ext.class_name)
          caller_types.each { |name, type| method_return_types[name] ||= type }
        end

        # Procurar chamadas ao método e extrair tipos dos keyword args
        matching_calls = Analyzer.find_all_nodes(file_result.value) { |n| n.is_a?(Prism::CallNode) && n.name == method_name.to_sym && n.arguments }
        matching_calls.each do |node|

          local_var_types = collect_local_var_types_for_scope(node, file_result, method_return_types, caller_ext.class_name)

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
      case node
      when Prism::LocalVariableReadNode
        local_var_types[node.name.to_s] || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          # receiver.method → tentar resolver
          receiver_type = resolve_arg_value_type(node.receiver, local_var_types, method_return_types)
          if receiver_type && receiver_type != "untyped"
            @method_type_resolver.resolve(receiver_type, node.name.to_s) || "untyped"
          else
            "untyped"
          end
        end
      when Prism::StringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node) || "untyped"
      when Prism::ImplicitNode
        resolve_arg_value_type(node.value, local_var_types, method_return_types)
      else
        "untyped"
      end
    end

    # Coleta tipos de variáveis locais no escopo do nó
    def collect_local_var_types_for_scope(target_node, parse_result, method_return_types, caller_class_name)
      local_var_types = {}

      # Encontrar o def encapsulante
      collector = DefCollector.new
      parse_result.value.accept(collector)

      enclosing_def = collector.defs.find do |defn|
        defn.location.start_offset <= target_node.location.start_offset &&
          defn.location.end_offset >= target_node.location.end_offset
      end

      return local_var_types unless enclosing_def

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
      all_assignments = Analyzer.find_all_nodes(enclosing_def) do |n|
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
            class_name = Analyzer.extract_constant_path(assign.value.receiver)
            if class_name
              local_var_types[var_name] = resolve_constant_in_namespace(class_name, caller_class_name)
            end
          else
            # receiver.method → tentar resolver tipo
            class_name = Analyzer.extract_constant_path(assign.value.receiver)
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
      block_calls = Analyzer.find_all_nodes(enclosing_def) do |n|
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

    # Extrai o tipo do elemento de uma coleção
    def extract_element_type(collection_type)
      # AR CollectionProxy: Foo::Bar::ActiveRecord_Associations_CollectionProxy → Foo::Bar
      if collection_type =~ /(.+)::ActiveRecord_Associations_CollectionProxy\z/
        return $1.sub(/\A::/, "")
      end
      # Array[Type] → Type
      if collection_type =~ /\AArray\[(.+)\]\z/
        return $1
      end
      nil
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
        return candidate if @source_files.any? { |f| f.end_with?("#{class_path}.rb") }
      end

      short_name
    end
  end
end
