# Fase 4 — Melhorias estruturais (opcional, breaking)

Mudanças mais invasivas que podem ser feitas numa versão futura. Cada item é independente.

---

## 4.1 Unificar parsers RBS — usar `RBS::Parser` em vez de regex

**Problema:** Existem 3 parsers RBS ad-hoc:
- `parse_rbs_class_block` — robusto, com suporte a nesting e absolute namespaces
- `build_rbs_collection_module_types` — simplificado, sem suporte a absolute namespaces
- `has_class_methods_module?` (em `RbsBuilder`) — outro parser ad-hoc

Inconsistências entre eles podem causar bugs em edge cases.

**Solução:** A gem RBS já é dependência. Usar `RBS::Parser.parse_signature(content)` para obter a AST oficial e navegar nos nós `RBS::AST::Declarations::Class`, `Module`, `Interface`, etc.

**Benefícios:**
- Suporte completo a todas as features de RBS (generics, interfaces, aliases)
- Nenhum bug de parsing
- Menos código para manter

**Riscos:**
- A API do `RBS::Parser` pode mudar entre versões
- Mais lento que regex para arquivos grandes (mas mais correto)

---

## 4.2 Indexação de source files

**Problema:** Iteração O(n×m) ao buscar referências a classes nos source files. `build_init_param_types`, `infer_attrs_from_call_sites`, `infer_wrapper_method_param_types` varrem todos os arquivos.

**Solução:** Criar um índice reverso na inicialização:

```ruby
module RbsInfer
  class SourceIndex
    def initialize(source_files)
      @index = Hash.new { |h, k| h[k] = [] }
      source_files.each do |file|
        content = File.read(file)
        # Extrair nomes de classes referenciadas (palavras CamelCase)
        content.scan(/\b([A-Z][a-zA-Z0-9]*)\b/).flatten.uniq.each do |name|
          @index[name] << file
        end
      end
    end

    # Retorna arquivos que provavelmente referenciam a classe
    def files_referencing(class_name)
      short_name = class_name.split("::").last
      @index[short_name] || []
    end
  end
end
```

**Uso:**
```ruby
# Em vez de:
@source_files.each do |file|
  source = File.read(file)
  next unless source.include?(short_name)
  # ...
end

# Usar:
@source_index.files_referencing(class_name).each do |file|
  # ...
end
```

**Benefícios:**
- Eliminaria leituras redundantes dos mesmos arquivos
- O scan inicial é ~O(n) e o lookup ~O(1)

**Riscos:**
- Consome memória para o índice (proporcional ao número de arquivos)
- O scan por CamelCase pode gerar false positives (melhor que false negatives)

---

## 4.3 Desnesting de classes — `RbsInfer::Analyzer::X` → `RbsInfer::X`

**Problema:** Todas as classes vivem dentro de `class Analyzer`, criando nomes longos como `RbsInfer::Analyzer::ClassMemberCollector` para classes que são conceitualmente independentes.

**Solução:** Mover para o namespace `RbsInfer::` diretamente:

```ruby
# Antes
module RbsInfer
  class Analyzer
  class TypeMerger     # RbsInfer::Analyzer::TypeMerger
  end
  end
end

# Depois
module RbsInfer
  class TypeMerger      # RbsInfer::TypeMerger
  end
end
```

**Classes candidatas a mover:**
- `TypeMerger`
- `RbsBuilder`
- `RbsTypeLookup`
- `RbsDefinitionResolver`
- `ReturnTypeResolver`
- `ParamTypeInferrer`
- `ClassMemberCollector`
- `ClassNameExtractor`
- `DefCollector`
- `OptionalParamExtractor`
- `NewCallCollector`
- `CallerFileAnalyzer`
- `ClassBodyAttrAnalyzer`
- `InitializeBodyAnalyzer`
- `IntraClassCallAnalyzer`

**Manter como inner class:**
- `Member` (Struct usado por `ClassMemberCollector`)

**Riscos:**
- **Breaking change** para qualquer usuário que referencia `RbsInfer::Analyzer::X`
- Muitos arquivos precisam ser atualizados
- Referências internas como `RbsInfer::Analyzer::ClassMemberCollector.new` precisam virar `RbsInfer::ClassMemberCollector.new`

**Estratégia de migração:**
1. Mover classes para `RbsInfer::`
2. Adicionar aliases temporários: `Analyzer::TypeMerger = RbsInfer::TypeMerger`
3. Deprecar os aliases na próxima minor version
4. Remover aliases na próxima major version

---

## Checklist

- [x] 4.1 — Unificar parsers RBS com `RBS::Parser` (commit `e6bf512`)
- [x] 4.2 — Criar `SourceIndex` para lookup eficiente (commit `bade607`)
- [x] 4.3 — Desnesting de classes para `RbsInfer::` (commit `92b2c7b`)
- [x] Rodar `bundle exec rspec` — 140 examples, 0 failures
- [x] Commit por item (cada um é independente)
