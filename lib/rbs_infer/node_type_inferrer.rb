module RbsInfer
  # Módulo compartilhado que unifica a inferência básica de tipos
  # a partir de nós da AST Prism. Cobre literais, constantes,
  # Klass.new, ImplicitNode, write nodes e leitura de variáveis.
  #
  # Classes que precisam de lógica mais complexa (chains, safe nav,
  # method resolution) incluem este módulo e adicionam sua própria
  # camada de resolução sobre o resultado de `infer_node_type`.
  module NodeTypeInferrer
    def infer_node_type(node, context_class: nil, known_types: {})
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then infer_hash_type(node)
      when Prism::InterpolatedRegularExpressionNode, Prism::RegularExpressionNode then "Regexp"
      when Prism::SelfNode then context_class
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
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

    def infer_hash_type(node)
      NodeTypeInferrer.infer_hash_type(node)
    end

    def self.infer_hash_type(node)
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
          value_type = infer_value_type(e.value)
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

    def self.infer_value_type(node)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then infer_hash_type(node)
      when Prism::InterpolatedRegularExpressionNode, Prism::RegularExpressionNode then "Regexp"
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node) || "untyped"
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          "untyped"
        end
      else
        "untyped"
      end
    end
  end
end
