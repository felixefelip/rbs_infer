# Análise do código da gem `rbs_infer`

## 1. Código duplicado massivamente: inferência de tipo a partir de nós AST

O problema mais significativo da gem é a **duplicação de 8+ implementações** de "inferir tipo de um nó Prism", cada uma com diferenças sutis:

| Arquivo | Método | Float? | Interpolated? | Regexp? | Self? | ImplicitNode? | Chains? |
|---|---|---|---|---|---|---|---|
| `class_member_collector.rb` | `infer_type_from_node` | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| `type_merger.rb` | `infer_literal_type` | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| `method_type_resolver.rb` | `infer_literal_return_type` | ✓ | ✓ | ✗ | ✓ | ✗ | parcial |
| `return_type_resolver.rb` | `infer_ivar_value_type` | ✓ | ✓ | ✗ | ✓ | ✗ | ✓ |
| `new_call_collector.rb` | `resolve_value_type` | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ |
| `intra_class_call_analyzer.rb` | `infer_expression_type` | ✗ | ✗ | ✗ | ✗ | ✗ | parcial |
| `initialize_body_analyzer.rb` | `infer_type_from_node` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| `class_body_attr_analyzer.rb` | `infer_type_from_node` | ✗ | ✗ | ✗ | ✗ | ✗ | parcial |
| `param_type_inferrer.rb` | `resolve_arg_value_type` | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ |

**Recomendação:** Extrair um módulo `NodeTypeInferrer` com um método principal `infer_node_type(node, context = {})` que receba opcionalmente um resolver para chains. Cada classe usaria esse módulo.

---

## 2. Arquivo-alvo parseado 8+ vezes

O `@target_file` é lido e parseado com `Prism.parse(File.read(@target_file))` em pelo menos 8 lugares distintos:

- `Analyzer#parse_target_class`
- `Analyzer#extract_optional_init_params`
- `Analyzer#infer_attr_types_from_initialize`
- `Analyzer#infer_attr_types_from_class_body`
- `ParamTypeInferrer#infer_method_param_types`
- `ReturnTypeResolver#improve_method_return_types`
- `ReturnTypeResolver#infer_ivar_types`
- `TypeMerger#resolve_method_return_types_from_attrs`

**Recomendação:** Parsear o target file **uma vez** no `Analyzer#generate_rbs` e passar o `Prism::ParseResult` (com `value`, `comments`, `source.lines`) para todos os resolvers. Isso eliminaria ~7 `File.read` + `Prism.parse` redundantes.

---

## 3. Construção de `known_return_types` duplicada 5+ vezes

O padrão de construir um hash de tipos conhecidos a partir de `members` + `attr_types` + `method_type_resolver.resolve_all` é repetido quase identicamente em:

- `ReturnTypeResolver#improve_method_return_types`
- `ReturnTypeResolver#infer_ivar_types`
- `TypeMerger#resolve_method_return_types_from_attrs`

**Recomendação:** Extrair um método `build_known_return_types(members, attr_types, method_type_resolver, target_class)` que retorne o hash pronto.

---

## 4. `rescue next` engole todas as exceções

Em `method_type_resolver.rb`, `param_type_inferrer.rb`, e outros:

```ruby
source = File.read(file) rescue next
```

Isso captura **qualquer** exceção (incluindo `NoMemoryError`, `TypeError`, bugs no código), não apenas erros de leitura de arquivo.

**Recomendação:** Usar `rescue Errno::ENOENT, Errno::EACCES => e` para ser explícito.

---

## 5. Todas as classes aninhadas sob `RbsInfer::Analyzer`

Todas os inner classes vivem dentro de `class Analyzer` usando o pattern de nesting com `end` compartilhado:

```ruby
module RbsInfer
  class Analyzer
  class ReturnTypeResolver  # ← RbsInfer::Analyzer::ReturnTypeResolver
```

Isso cria um acoplamento de namespace artificial. Classes como `TypeMerger`, `RbsBuilder`, `RbsTypeLookup` são independentes do `Analyzer` conceitualmente. Referências internas precisam usar `RbsInfer::Analyzer::ClassMemberCollector` em vez de apenas `ClassMemberCollector`.

**Recomendação:** Mover classes utilitárias para `RbsInfer::` diretamente (ex: `RbsInfer::TypeMerger`, `RbsInfer::RbsBuilder`). Manter como inner classes apenas aquelas que fazem parte do ciclo de vida do Analyzer.

---

## 6. `parse_rbs_class_block` retorna 4 valores, callers usam 3

Em `rbs_type_lookup.rb`, `parse_rbs_class_block` retorna `[superclass, types, includes, class_method_types]`, mas a maioria dos callers faz:

```ruby
sc, ts, incs = parse_rbs_class_block(content, normalized)
# class_method_types silenciosamente descartado
```

Apenas `lookup_class_methods` usa o 4º valor. Isso é frágil e pode esconder bugs.

**Recomendação:** Retornar um Struct/Data object em vez de array:

```ruby
RbsClassInfo = Data.define(:superclass, :types, :includes, :class_method_types)
```

---

## 7. Dois parsers de RBS diferentes e inconsistentes

`parse_rbs_class_block` é um parser robusto com suporte a nesting, absolute namespaces (`::Foo`), e vários tipos de declaração. Mas `build_rbs_collection_module_types` em `rbs_type_lookup.rb` tem **seu próprio parser simplificado** que não suporta absolute namespaces nem nesting correto. Da mesma forma, `has_class_methods_module?` em `rbs_builder.rb` tem **outro parser ad-hoc**.

**Recomendação:** Unificar tudo usando `parse_rbs_class_block` como parser central, ou melhor, usar a API do `RBS::Parser` da gem RBS diretamente (que já é dependência) em vez de parsers regex.

---

## 8. Conversão CamelCase → snake_case duplicada e com bugs

O pattern `class_name.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase` aparece em 5+ lugares. Além da duplicação, o regex **não funciona para acrônimos**: `HTMLParser` vira `htmlparser` em vez de `html_parser`.

**Recomendação:** Extrair um método utilitário `RbsInfer.class_to_path(class_name)` e usar `ActiveSupport::Inflector.underscore` se Rails estiver disponível, ou cuidar de sequências maiúsculas: `gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z])([A-Z])/, '\1_\2')`.

---

## 9. `chomp("?")` para tipos opcionais é frágil

Em `return_type_resolver.rb` e outros:

```ruby
base_type = safe_nav ? receiver_type.chomp("?") : receiver_type
```

Funciona para `String?` → `String`, mas falha para:
- `(String | Integer)?` → não remove o `?` (não termina com `?` isolado)
- `Hash[Symbol, String]?` → funciona mas é coincidência

**Recomendação:** Usar `type.delete_suffix("?")` ou um parser de tipos RBS para strip de opcionalidade.

---

## 10. `CallerFileAnalyzer` duplica lógica do `ClassMemberCollector`

`CallerFileAnalyzer` reimplementa `find_rbs_return_type` e `lines_between_are_blank_or_comments` que já existem em `ClassMemberCollector`.

**Recomendação:** Reutilizar `ClassMemberCollector` internamente ou extrair os métodos de parsing de anotações para um módulo compartilhado.

---

## 11. Performance: iteração O(n×m) sem indexação

`build_init_param_types`, `infer_attrs_from_call_sites`, `infer_wrapper_method_param_types` e `infer_method_param_types_from_callers` iteram **todos** os `source_files` para encontrar referências a uma classe. Para projetos Rails grandes (10k+ arquivos), isso é muito lento.

**Recomendação:** Criar um índice reverso na inicialização: `short_class_name → [files that contain it]` usando `grep -l` ou um scan rápido. Depois filtrar por esse índice antes da análise completa.

---

## 12. Inconsistência: `ITERATOR_METHODS` definido em dois lugares

`analyzer.rb` define `ITERATOR_METHODS` e `param_type_inferrer.rb` faz `ITERATOR_METHODS = Analyzer::ITERATOR_METHODS`. Se `Analyzer::ITERATOR_METHODS` for removido, o `ParamTypeInferrer` quebra silenciosamente em tempo de carga.

**Recomendação:** Definir a constante em um único lugar (no módulo `RbsInfer` ou em um módulo `Constants`).

---

## 13. Guard checks redundantes antes de `extract_constant_path`

Em múltiplos lugares:

```ruby
if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
  class_name = Analyzer.extract_constant_path(node.receiver)
```

Mas `extract_constant_path` já trata esses tipos e retorna `nil` para outros. O `if` é redundante.

**Recomendação:** Remover os guards e confiar no retorno `nil` de `extract_constant_path`.

---

## Resumo priorizado

| Prioridade | Problema | Impacto | Esforço |
|---|---|---|---|
| 🔴 Alta | Tipo AST inferido duplicado 8x | Bugs sutis, manutenção difícil | Médio |
| 🔴 Alta | Target file parseado 8x | Performance degradada | Baixo |
| 🟡 Média | `known_return_types` duplicado 5x | Manutenção difícil | Baixo |
| 🟡 Média | `rescue next` engole exceções | Bugs silenciosos | Mínimo |
| 🟡 Média | Dois parsers RBS inconsistentes | Bugs em casos edge | Médio |
| 🟡 Média | Sem indexação de source files | Performance O(n×m) | Médio |
| 🟢 Baixa | Classes aninhadas sob Analyzer | Acoplamento artificial | Alto (breaking) |
| 🟢 Baixa | `parse_rbs_class_block` retorna array | Fragilidade API | Baixo |
| 🟢 Baixa | CamelCase→snake_case duplicado | DRY, bugs acrônimos | Mínimo |
| 🟢 Baixa | `chomp("?")` frágil | Edge cases tipos union | Mínimo |
