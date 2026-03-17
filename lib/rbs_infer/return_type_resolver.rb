module RbsInfer
  class Analyzer
  # Resolve return types de métodos e tipos de instance variables
  # a partir de análise estática do corpo dos métodos.
  #
  # Extraído de Analyzer para manter responsabilidades separadas:
  # - improve_method_return_types: resolve return types de métodos via chain resolution
  # - infer_ivar_types: infere tipos de instance variables (@post, @posts, etc.)

  class ReturnTypeResolver
    def initialize(target_file:, target_class:, method_type_resolver:)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
    end

    def improve_method_return_types(members, attr_types)
      return unless @target_file && File.exist?(@target_file)

      # Métodos com return type untyped
      untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\s*untyped$/ }
      return if untyped_methods.empty?

      source = File.read(@target_file)
      result = Prism.parse(source)

      known_return_types = {}
      attr_types.each { |name, type| known_return_types[name] = type }
      members.each do |m|
        case m.kind
        when :method
          if m.signature =~ /->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
            known_return_types[m.name] = $1.strip
          end
        when :attr_accessor, :attr_reader
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            known_return_types[m.name] = type unless type == "untyped"
          end
        end
      end

      if method_type_resolver
        resolver_types = method_type_resolver.resolve_all(@target_class)
        resolver_types.each { |name, type| known_return_types[name] ||= type }
      end

      # Aplicar tipos já resolvidos pelo resolver (ex: chamadas a métodos herdados)
      untyped_methods.each do |m|
        resolved = known_return_types[m.name]
        if resolved && resolved != "untyped"
          m.signature = m.signature.sub(/-> untyped$/, "-> #{resolved}")
        end
      end
      untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\s*untyped$/ }

      untyped_names = untyped_methods.map(&:name).to_set

      collector = DefCollector.new
      result.value.accept(collector)

      collector.defs.each do |defn|
        next unless defn.is_a?(Prism::DefNode)
        next unless untyped_names.include?(defn.name.to_s)

        body = defn.body
        last_stmt = case body
                    when Prism::StatementsNode then body.body.last
                    else body
                    end
        next unless last_stmt

        # Coletar tipos de variáveis locais do corpo do método
        method_known_types = known_return_types.dup
        if body.is_a?(Prism::StatementsNode)
          body.body[0...-1].each do |stmt|
            collect_local_var_type(stmt, method_known_types)
          end
        end

        resolved = infer_ivar_value_type(last_stmt, method_known_types)
        next unless resolved && resolved != "untyped"

        member = untyped_methods.find { |m| m.name == defn.name.to_s }
        member.signature = member.signature.sub(/-> untyped$/, "-> #{resolved}")
      end
    end

    def infer_ivar_types(members, attr_types)
      return {} unless @target_file && File.exist?(@target_file)

      source = File.read(@target_file)
      result = Prism.parse(source)

      # Montar known_return_types com tudo que já sabemos
      known_return_types = {}
      attr_types.each { |name, type| known_return_types[name] = type }
      members.each do |m|
        case m.kind
        when :method
          if m.signature =~ /->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
            known_return_types[m.name] = $1.strip
          end
        when :attr_accessor, :attr_reader
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            known_return_types[m.name] = type unless type == "untyped"
          end
        end
      end

      if method_type_resolver
        resolver_types = method_type_resolver.resolve_all(@target_class)
        resolver_types.each { |name, type| known_return_types[name] ||= type }
      end

      # Nomes de attrs já declarados (attr_accessor, attr_reader) → pular
      attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                          .map(&:name).to_set

      ivar_types = {}

      # Coletar todos os InstanceVariableWriteNode
      collector = DefCollector.new
      result.value.accept(collector)

      # Dois passes: o segundo resolve ivars que dependem de outros (@comments depende de @post)
      2.times do
        collector.defs.each do |defn|
          collect_ivar_writes(defn, known_return_types, ivar_types, attr_names)
        end
      end

      ivar_types
    end

    private

    attr_reader :method_type_resolver

    def collect_local_var_type(node, known_types)
      case node
      when Prism::LocalVariableWriteNode
        type = infer_ivar_value_type(node.value, known_types)
        known_types[node.name.to_s] = type if type && type != "untyped"
      end
    end

    def collect_ivar_writes(node, known_return_types, ivar_types, attr_names)
      queue = [node]
      while (current = queue.shift)
        if current.is_a?(Prism::InstanceVariableWriteNode)
          name = current.name.to_s.sub(/\A@/, "")
          next if attr_names.include?(name)
          next if ivar_types[name] && ivar_types[name] != "untyped"

          inferred = infer_ivar_value_type(current.value, known_return_types)
          if inferred && inferred != "untyped"
            ivar_types[name] = inferred
            known_return_types[name] = inferred
          end
        end
        queue.concat(current.compact_child_nodes)
      end
    end

    def infer_ivar_value_type(node, known_return_types)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then "Hash[untyped, untyped]"
      when Prism::SelfNode then @target_class
      when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode
        infer_ivar_value_type(node.value, known_return_types)
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
        elsif node.receiver.nil?
          # Chamada sem receiver (self implícito): ex. posts, comments
          resolved = known_return_types[node.name.to_s]
          return resolved if resolved

          infer_block_return_type(node.block, known_return_types)
        else
          # Verificar se receiver é uma constante (chamada de classe)
          if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
            class_name = Analyzer.extract_constant_path(node.receiver)
            if class_name && method_type_resolver
              resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
              return (resolved == "self" ? class_name : resolved) if resolved
            end
          end

          # Chain: receiver.method → resolver tipo do receiver, depois do method
          receiver_type = resolve_chain_type(node.receiver, known_return_types)
          if receiver_type && receiver_type != "untyped"
            safe_nav = node.call_operator == "&."
            base_type = safe_nav ? receiver_type.chomp("?") : receiver_type
            resolved = resolve_on_type(base_type, node.name.to_s)
            resolved = if resolved == "self" then receiver_type
                       elsif resolved && safe_nav && !resolved.end_with?("?") then "#{resolved}?"
                       else resolved
                       end
            return resolved if resolved

            infer_block_return_type(node.block, known_return_types)
          end
        end
      end
    end

    def infer_block_return_type(block_node, known_return_types)
      return nil unless block_node.is_a?(Prism::BlockNode)

      body = block_node.body
      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end
      return nil unless last_stmt

      infer_ivar_value_type(last_stmt, known_return_types)
    end

    def resolve_on_type(receiver_type, method_name)
      return nil unless method_type_resolver
      method_type_resolver.resolve(receiver_type, method_name)
    end

    def resolve_chain_type(node, known_return_types)
      case node
      when Prism::CallNode
        if node.receiver.nil?
          known_return_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
        else
          # Verificar se receiver é uma constante (chamada de classe)
          if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
            class_name = Analyzer.extract_constant_path(node.receiver)
            if class_name && method_type_resolver
              resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
              return (resolved == "self" ? class_name : resolved) if resolved
            end
          end

          parent_type = resolve_chain_type(node.receiver, known_return_types)
          if parent_type && parent_type != "untyped"
            safe_nav = node.call_operator == "&."
            base_type = safe_nav ? parent_type.chomp("?") : parent_type
            resolved = resolve_on_type(base_type, node.name.to_s)
            resolved = if resolved == "self" then parent_type
                       elsif resolved && safe_nav && !resolved.end_with?("?") then "#{resolved}?"
                       else resolved
                       end
            return resolved if resolved

            infer_block_return_type(node.block, known_return_types)
          end
        end
      when Prism::SelfNode
        nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      when Prism::InstanceVariableReadNode
        known_return_types[node.name.to_s.sub(/\A@/, "")]
      when Prism::LocalVariableReadNode
        known_return_types[node.name.to_s]
      end
    end
  end
  end
end
