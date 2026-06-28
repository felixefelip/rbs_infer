module RbsInfer::AST
  # Módulo compartilhado que unifica a inferência básica de tipos
  # a partir de nós da AST Prism. Cobre literais, constantes,
  # Klass.new, ImplicitNode, write nodes e leitura de variáveis.
  #
  # Classes que precisam de lógica mais complexa (chains, safe nav,
  # method resolution) incluem este módulo e adicionam sua própria
  # camada de resolução sobre o resultado de `infer_node_type`.
  module NodeTypeInferrer
    # Abstract: every includer must declare its resolver explicitly
    # (felixefelip/rbs_infer#56). Includers that type constants in VALUE position
    # (a constant as a return, ivar, hash value, default, …) provide a real
    # `ConstantArgTypeResolver` so the type is the constant's VALUE type, not its
    # bare name (invalid RBS for a value constant, and env-poisoning) — typically
    # via `attr_reader :constant_resolver`. Purely structural includers that never
    # type value-position constants override with an explicit `nil`. Not defaulted
    # to nil: a future includer that types value constants but forgets to override
    # would silently degrade them to untyped; raising forces a conscious choice.
    def constant_resolver
      raise NotImplementedError, "#{self.class} must declare #constant_resolver (a ConstantArgTypeResolver, or nil if it never types value-position constants)"
    end

    def infer_node_type(node, context_class: nil, known_types: {})
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then infer_hash_type(node, context_class: context_class, known_types: known_types)
      when Prism::InterpolatedRegularExpressionNode, Prism::RegularExpressionNode then "Regexp"
      when Prism::SelfNode then context_class
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        NodeTypeInferrer.resolve_constant_value_type(node, namespace: context_class, constant_resolver: constant_resolver)
      when Prism::CallNode
        if node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        elsif node.receiver.nil?
          known_types[node.name.to_s]
        end
      when Prism::ImplicitNode
        infer_node_type(node.value, context_class: context_class, known_types: known_types)
      when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode
        infer_node_type(node.value, context_class: context_class, known_types: known_types)
      when Prism::LocalVariableReadNode
        known_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        known_types[node.name.to_s.sub(/\A@/, "")]
      end
    end

    def infer_hash_type(node, context_class: nil, known_types: {})
      NodeTypeInferrer.infer_hash_type(node, known_types: known_types, context_class: context_class, constant_resolver: constant_resolver)
    end

    # Resolves a bare-constant node to its VALUE type via the resolver, or nil
    # when none/unresolved — never the bare name (#56). Shared by the instance
    # method and the module-level value/hash typers.
    def self.resolve_constant_value_type(node, namespace:, constant_resolver:)
      return nil unless constant_resolver
      constant_resolver.resolve(name: RbsInfer::Analyzer.extract_constant_path(node), namespace: namespace)
    end

    def self.infer_hash_type(node, known_types: {}, context_class: nil, constant_resolver: nil)
      elements = node.elements
      return "Hash[untyped, untyped]" if elements.empty?

      # Splat present → can't determine full shape
      return "Hash[Symbol, untyped]" if elements.any? { |e| e.is_a?(Prism::AssocSplatNode) }

      assocs = elements.select { |e| e.is_a?(Prism::AssocNode) }
      return "Hash[untyped, untyped]" if assocs.empty?

      all_symbol_keys = assocs.all? { |e| e.key.is_a?(Prism::SymbolNode) }

      if all_symbol_keys
        # Record type: { key: Type, ... }
        pairs = assocs.map { |e|
          key_name = e.key.unescaped
          value_type = infer_value_type(e.value, known_types: known_types, context_class: context_class, constant_resolver: constant_resolver)
          "#{key_name}: #{value_type}"
        }
        "{ #{pairs.join(", ")} }"
      else
        key_types = assocs.filter_map { |e|
          case e.key
          when Prism::SymbolNode then "Symbol"
          when Prism::StringNode then "String"
          when Prism::IntegerNode then "Integer"
          end
        }.uniq
        key_type = key_types.size == 1 ? key_types.first : "untyped"
        "Hash[#{key_type}, untyped]"
      end
    end

    def self.infer_value_type(node, known_types: {}, context_class: nil, constant_resolver: nil)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then infer_hash_type(node, known_types: known_types, context_class: context_class, constant_resolver: constant_resolver)
      when Prism::InterpolatedRegularExpressionNode, Prism::RegularExpressionNode then "Regexp"
      when Prism::SelfNode then context_class || "untyped"
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        resolve_constant_value_type(node, namespace: context_class, constant_resolver: constant_resolver) || "untyped"
      when Prism::CallNode
        if node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        elsif node.receiver.nil?
          known_types[node.name.to_s] || "untyped"
        else
          "untyped"
        end
      when Prism::LocalVariableReadNode
        known_types[node.name.to_s] || "untyped"
      when Prism::InstanceVariableReadNode
        known_types[node.name.to_s.sub(/\A@/, "")] || "untyped"
      else
        "untyped"
      end
    end
  end
end
