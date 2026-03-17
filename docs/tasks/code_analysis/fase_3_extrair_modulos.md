# Fase 3 — Extrair módulos compartilhados

Depende da Fase 2 (interfaces estáveis). Maior volume de mudanças, mas com testes controlando.

---

## 3.1 Extrair `NodeTypeInferrer`

**Problema:** 8+ implementações diferentes de "inferir tipo de um nó Prism AST", cada uma com capacidades distintas (suporte a Float, InterpolatedString, Regexp, Self, ImplicitNode, chains).

**Solução:** Criar um módulo `NodeTypeInferrer` com um método unificado:

```ruby
# lib/rbs_infer/node_type_inferrer.rb
module RbsInfer
  module NodeTypeInferrer
    # Infere o tipo de qualquer nó Prism AST.
    # Opções:
    #   context_class: nome da classe para resolver `self`
    #   method_type_resolver: resolver para chains (receiver.method)
    #   known_types: hash de tipos conhecidos (attrs, variáveis locais)
    def infer_node_type(node, context_class: nil, method_type_resolver: nil, known_types: {})
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
      when Prism::ImplicitNode
        infer_node_type(node.value, context_class: context_class,
                        method_type_resolver: method_type_resolver, known_types: known_types)
      when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode
        infer_node_type(node.value, context_class: context_class,
                        method_type_resolver: method_type_resolver, known_types: known_types)
      when Prism::LocalVariableReadNode
        known_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        known_types[node.name.to_s.sub(/\A@/, "")]
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      when Prism::CallNode
        infer_call_node_type(node, context_class: context_class,
                             method_type_resolver: method_type_resolver, known_types: known_types)
      end
    end

    private

    def infer_call_node_type(node, context_class:, method_type_resolver:, known_types:)
      if node.name == :new && node.receiver
        Analyzer.extract_constant_path(node.receiver)
      elsif node.receiver.nil?
        known_types[node.name.to_s]
      elsif method_type_resolver
        class_name = Analyzer.extract_constant_path(node.receiver)
        if class_name
          method_type_resolver.resolve_class_method(class_name, node.name.to_s)
        else
          receiver_type = infer_node_type(node.receiver, context_class: context_class,
                                          method_type_resolver: method_type_resolver, known_types: known_types)
          method_type_resolver.resolve(receiver_type, node.name.to_s) if receiver_type && receiver_type != "untyped"
        end
      end
    end
  end
end
```

**Classes que fariam `include NodeTypeInferrer`:**
- `ClassMemberCollector` — substituir `infer_type_from_node`
- `TypeMerger` — substituir `infer_literal_type`
- `MethodTypeResolver` — substituir `infer_literal_return_type`
- `ReturnTypeResolver` — substituir `infer_ivar_value_type` (parcialmente)
- `NewCallCollector` — substituir `resolve_value_type`
- `IntraClassCallAnalyzer` — substituir `infer_expression_type`
- `InitializeBodyAnalyzer` — substituir `infer_type_from_node`
- `ClassBodyAttrAnalyzer` — substituir `infer_type_from_node`
- `ParamTypeInferrer` — substituir `resolve_arg_value_type`

Alguns desses métodos fazem mais do que inferência pura (ex: `ReturnTypeResolver#infer_ivar_value_type` também resolve chains com safe navigation). Nesses casos, o método local chama `infer_node_type` para a parte básica e adiciona lógica específica.

---

## 3.2 Extrair `KnownReturnTypesBuilder`

**Problema:** O padrão de construir um `known_return_types` hash a partir de `members` + `attr_types` + `method_type_resolver.resolve_all` é repetido 3+ vezes identicamente.

**Solução:**

```ruby
# lib/rbs_infer/known_return_types_builder.rb
module RbsInfer
  module KnownReturnTypesBuilder
    def build_known_return_types(members, attr_types, method_type_resolver: nil, target_class: nil)
      types = {}
      attr_types.each { |name, type| types[name] = type }

      members.each do |m|
        case m.kind
        when :method
          if m.signature =~ /->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
            types[m.name] = $1.strip
          end
        when :attr_accessor, :attr_reader
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            types[m.name] = type unless type == "untyped"
          end
        end
      end

      if method_type_resolver && target_class
        resolver_types = method_type_resolver.resolve_all(target_class)
        resolver_types.each { |name, type| types[name] ||= type }
      end

      types
    end
  end
end
```

**Classes que usariam:**
- `ReturnTypeResolver` — `improve_method_return_types` e `infer_ivar_types`
- `TypeMerger` — `resolve_method_return_types_from_attrs`

---

## 3.3 `parse_rbs_class_block` → retornar `Data.define`

**Problema:** Retorna array de 4 elementos, callers usam 3, fácil errar posição.

**Antes:**
```ruby
def parse_rbs_class_block(content, class_name)
  # ...
  [superclass, types, includes, class_method_types]
end

# callers:
sc, ts, incs = parse_rbs_class_block(content, normalized)
```

**Depois:**
```ruby
RbsClassInfo = Data.define(:superclass, :types, :includes, :class_method_types)

def parse_rbs_class_block(content, class_name)
  # ...
  RbsClassInfo.new(superclass: superclass, types: types, includes: includes, class_method_types: class_method_types)
end

# callers:
info = parse_rbs_class_block(content, normalized)
info.superclass
info.types
info.includes
```

---

## 3.4 Extrair parsing de anotações RBS para módulo compartilhado

**Problema:** `CallerFileAnalyzer` reimplementa `find_rbs_return_type` e `lines_between_are_blank_or_comments` que já existem em `ClassMemberCollector`.

**Solução:** Extrair um módulo `RbsAnnotationParser`:

```ruby
module RbsInfer
  module RbsAnnotationParser
    def find_rbs_return_type(comments, lines, def_line)
      # lógica unificada
    end

    def lines_between_are_blank_or_comments(lines, from_line, to_line)
      # lógica unificada
    end
  end
end
```

**Classes que fariam `include RbsAnnotationParser`:**
- `ClassMemberCollector`
- `CallerFileAnalyzer`

---

## Checklist

- [ ] 3.1 — Criar `NodeTypeInferrer` e incluir em todas as classes
- [ ] 3.2 — Criar `KnownReturnTypesBuilder` e usar em `ReturnTypeResolver` e `TypeMerger`
- [ ] 3.3 — `parse_rbs_class_block` retornar `RbsClassInfo`
- [ ] 3.4 — Extrair `RbsAnnotationParser`
- [ ] Rodar `bundle exec rspec` — 0 failures
- [ ] Commit
