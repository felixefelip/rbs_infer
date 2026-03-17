module RbsInfer
  # Resolve return types de métodos e tipos de instance variables
  # a partir de análise estática do corpo dos métodos.
  #
  # Extraído de Analyzer para manter responsabilidades separadas:
  # - improve_method_return_types: resolve return types de métodos via chain resolution
  # - infer_ivar_types: infere tipos de instance variables (@post, @posts, etc.)

  class ReturnTypeResolver
    include NodeTypeInferrer
    include KnownReturnTypesBuilder

    def initialize(target_file:, target_class:, method_type_resolver:, instance_types: [], steep_bridge: nil)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @instance_types = instance_types
      @steep_bridge = steep_bridge
    end

    def improve_method_return_types(members, attr_types, parsed_target: nil)
      return unless parsed_target

      # Métodos com return type untyped
      untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\ s*untyped$/ }
      return if untyped_methods.empty?

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)

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
      parsed_target.tree.accept(collector)

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

        # Se há return nil no corpo, tornar nilable
        if has_nil_return?(defn) && !resolved.end_with?("?")
          resolved = "#{resolved}?"
        end

        member = untyped_methods.find { |m| m.name == defn.name.to_s }
        member.signature = member.signature.sub(/-> untyped$/, "-> #{resolved}")
      end

      # Final pass: use Steep for any remaining untyped methods
      if @steep_bridge && parsed_target.source
        still_untyped = members.select { |m| m.kind == :method && m.name != "initialize" && m.signature =~ /->\s*untyped$/ }
        unless still_untyped.empty?
          steep_returns = @steep_bridge.method_return_types(parsed_target.source)
          still_untyped.each do |m|
            steep_type = steep_returns[m.name]
            if steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
              m.signature = m.signature.sub(/-> untyped$/, "-> #{steep_type}")
            end
          end
        end
      end
    end

    def infer_ivar_types(members, attr_types, parsed_target: nil)
      return {} unless parsed_target

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)

      # Nomes de attrs já declarados (attr_accessor, attr_reader) → pular
      attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                          .map(&:name).to_set

      ivar_types = {}

      # Coletar todos os InstanceVariableWriteNode
      collector = DefCollector.new
      parsed_target.tree.accept(collector)

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

    # Verifica se o corpo do método contém `return nil` ou `return` (implícito nil)
    def has_nil_return?(defn)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        # return sem argumentos = return nil
        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
    end

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
      when Prism::ParenthesesNode
        body = node.body
        inner = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        infer_ivar_value_type(inner, known_return_types) if inner
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
          class_name = Analyzer.extract_constant_path(node.receiver)
          if class_name && method_type_resolver
            resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
            return (resolved == "self" ? class_name : resolved) if resolved
          end

          # Chain: receiver.method → resolver tipo do receiver, depois do method
          receiver_type = resolve_chain_type(node.receiver, known_return_types)
          if receiver_type && receiver_type != "untyped"
            safe_nav = node.call_operator == "&."
            base_type = safe_nav ? receiver_type.delete_suffix("?") : receiver_type
            block_body_type = node.block ? infer_block_return_type(node.block, known_return_types) : nil
            resolved = resolve_on_type(base_type, node.name.to_s, block_body_type: block_body_type)
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

    def resolve_on_type(receiver_type, method_name, block_body_type: nil)
      return nil unless method_type_resolver
      method_type_resolver.resolve(receiver_type, method_name, block_body_type: block_body_type)
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
          class_name = Analyzer.extract_constant_path(node.receiver)
          if class_name && method_type_resolver
            resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
            return (resolved == "self" ? class_name : resolved) if resolved
          end

          parent_type = resolve_chain_type(node.receiver, known_return_types)
          if parent_type && parent_type != "untyped"
            safe_nav = node.call_operator == "&."
            base_type = safe_nav ? parent_type.delete_suffix("?") : parent_type
            block_body_type = node.block ? infer_block_return_type(node.block, known_return_types) : nil
            resolved = resolve_on_type(base_type, node.name.to_s, block_body_type: block_body_type)
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
      when Prism::ParenthesesNode
        body = node.body
        inner = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        resolve_chain_type(inner, known_return_types) if inner
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
