module RbsInfer
  class TypeMerger
    include NodeTypeInferrer
    include KnownReturnTypesBuilder

    # Métodos de Array que retornam self (o próprio array)
    ARRAY_SELF_RETURN_METHODS = %i[<< push append unshift prepend insert concat].to_set

    def initialize(target_file:, target_class: nil)
      @target_file = target_file
      @target_class = target_class
    end

    # ─── Unificar tipos de múltiplos call-sites ────────────────────────

    def merge_argument_types(usages)
      all_types = Hash.new { |h, k| h[k] = [] }

      usages.each do |usage|
        usage.each do |arg_name, type|
          all_types[arg_name] << type
        end
      end

      merged = {}
      all_types.each do |arg_name, types|
        # Preferir tipos resolvidos sobre untyped
        resolved = types.reject { |t| t == "untyped" }
        resolved = types if resolved.empty?

        # Normalizar :: prefix e deduplicar
        unique = resolved.map { |t| t.sub(/\A::/, "") }.uniq
        merged[arg_name] = unique.size == 1 ? unique.first : "(#{unique.join(" | ")})"
      end

      merged
    end

    # ─── Resolver return types de métodos que retornam attrs ────────
    # Após inferir attr_types, re-examina métodos com return "untyped"
    # e substitui pelo tipo do attr se a última expressão do método
    # for uma chamada implícita a um attr conhecido.

    def resolve_method_return_types_from_attrs(members, attr_types, method_type_resolver: nil, parsed_target: nil)
      return unless parsed_target

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class)

      # Coletar mapeamento: method_name -> última expressão do body
      method_last_exprs = {}
      collector = DefCollector.new
      parsed_target.tree.accept(collector)

      collector.defs.each do |defn|
        body = defn.body
        next unless body

        last_stmt = case body
                    when Prism::StatementsNode then body.body.last
                    else body
                    end
        next unless last_stmt

        method_name = defn.name.to_s
        member = members.find { |m| m.kind == :method && m.name == method_name }
        next unless member
        next unless member.signature.end_with?("-> untyped")

        # 1. Literal na última expressão
        literal_type = infer_literal_type(last_stmt)
        if literal_type
          member.signature = member.signature.sub("-> untyped", "-> #{literal_type}")
          known_return_types[method_name] = literal_type
          next
        end

        # 2. Klass.new(...) na última expressão
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.name == :new && last_stmt.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(last_stmt.receiver)
          if class_name
            member.signature = member.signature.sub("-> untyped", "-> #{class_name}")
            known_return_types[method_name] = class_name
            next
          end
        end

        # 3. Chamada implícita a self (ex: `endereco` sem receiver)
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver.nil? && last_stmt.arguments.nil?
          method_last_exprs[method_name] = last_stmt.name.to_s
        end

        # 4. attr.mutation_method(expr) → return type é o tipo do attr (Array retorna self)
        if last_stmt.is_a?(Prism::CallNode) && ARRAY_SELF_RETURN_METHODS.include?(last_stmt.name) && last_stmt.receiver
          receiver_name = implicit_self_method_name(last_stmt.receiver)
          if receiver_name && known_return_types[receiver_name]
            resolved = known_return_types[receiver_name]
            member.signature = member.signature.sub("-> untyped", "-> #{resolved}")
            known_return_types[method_name] = resolved
            next
          end
        end

        # 5. receiver.method() na última expressão
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver && method_type_resolver
          resolved = infer_call_return_type(last_stmt, known_return_types, method_type_resolver)
          if resolved
            member.signature = member.signature.sub("-> untyped", "-> #{resolved}")
            known_return_types[method_name] = resolved
            next
          end
        end
      end

      # Atualizar signatures de métodos que retornam attrs/métodos conhecidos
      members.each do |member|
        next unless member.kind == :method
        next unless member.signature.end_with?("-> untyped")

        called_name = method_last_exprs[member.name]
        next unless called_name

        resolved_type = known_return_types[called_name]
        next unless resolved_type

        member.signature = member.signature.sub("-> untyped", "-> #{resolved_type}")
      end
    end

    private

    # Extrai nome do método quando o receiver é self implícito ou explícito
    def implicit_self_method_name(node)
      return unless node.is_a?(Prism::CallNode)
      return node.name.to_s if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    # Resolve return type de receiver.method() ou method() com args
    def infer_call_return_type(call_node, known_return_types, method_type_resolver)
      if call_node.receiver.nil?
        # Chamada sem receiver (self implícito) com argumentos
        known_return_types[call_node.name.to_s]
      elsif call_node.name == :new && call_node.receiver
        RbsInfer::Analyzer.extract_constant_path(call_node.receiver)
      else
        # receiver.method → resolver tipo do receiver, depois do method
        receiver_type = resolve_receiver_type(call_node.receiver, known_return_types, method_type_resolver)
        if receiver_type && receiver_type != "untyped"
          resolved = method_type_resolver.resolve(receiver_type, call_node.name.to_s)
          resolved == "self" ? receiver_type : resolved
        end
      end
    end

    def resolve_receiver_type(node, known_return_types, method_type_resolver)
      case node
      when Prism::CallNode
        if node.receiver.nil?
          known_return_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        else
          parent_type = resolve_receiver_type(node.receiver, known_return_types, method_type_resolver)
          if parent_type && parent_type != "untyped"
            resolved = method_type_resolver.resolve(parent_type, node.name.to_s)
            # "self" means the method returns the same type as the receiver
            resolved == "self" ? parent_type : resolved
          end
        end
      when Prism::SelfNode
        nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        RbsInfer::Analyzer.extract_constant_path(node)
      when Prism::LocalVariableReadNode
        known_return_types[node.name.to_s]
      end
    end

    def infer_literal_type(node)
      infer_node_type(node)
    end
  end
end
