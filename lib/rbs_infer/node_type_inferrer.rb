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
      when Prism::HashNode then "Hash[untyped, untyped]"
      when Prism::InterpolatedRegularExpressionNode, Prism::RegularExpressionNode then "Regexp"
      when Prism::SelfNode then context_class
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
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
  end
end
