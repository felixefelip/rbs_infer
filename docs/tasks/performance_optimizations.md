# Performance Optimizations

A inferência de tipos está lenta para projetos grandes (minutos para rodar os testes de integração). Abaixo estão os gargalos identificados, ordenados por impacto.

## Gargalos

### 1. Múltiplos visitors no mesmo arquivo parseado

**Localização**: `lib/rbs_infer/method_type_resolver.rb`

Para cada arquivo de caller, o código roda 3–4 `accept()` separados no mesmo `result.value`: `ClassNameExtractor`, `ClassMemberCollector`, `DefCollector`, `NewCallCollector`. Isso significa 3–4 traversals completos do AST por arquivo.

**Fix**: Um único traversal por arquivo que coleta tudo de uma vez.

**Implementado**: `lib/rbs_infer/caller_file_cache.rb` — cache de `CallerFileAnalysis` (members + class_name + defs) compartilhado entre `MethodTypeResolver` e `ParamTypeInferrer`. Reduz de 3–4 `accept()` para 1 por arquivo de caller.
**Resultado medido**: tempo dos testes de integração reduziu de **2min 35s → 2min 31s** (~3% de ganho adicional).
**Por que abaixo do esperado**: o custo dominante (I/O + `Prism.parse`) já havia sido eliminado pelo `ParseCache`. Traversal de AST em memória é rápido. Além disso, a taxa de cache hits é baixa — na prática cada arquivo de caller é visitado poucas vezes por análise, então o cache raramente é aproveitado.

---

### 2. Mesmos arquivos lidos e parseados múltiplas vezes

**Localização**: `lib/rbs_infer/method_type_resolver.rb:70-119` e `272-338`

`build_init_param_types` e `infer_attrs_from_call_sites` iteram separadamente sobre `files_referencing(class_name)`, fazendo `File.read` + `Prism.parse` nos mesmos arquivos em passes distintos. I/O e parse são as operações mais caras.

**Fix**: Cache de `Prism.parse` por arquivo — parsear uma vez, reutilizar o resultado.

```ruby
@parse_cache = {}

def parsed(file)
  @parse_cache[file] ||= Prism.parse(File.read(file))
end
```

**Implementado**: `lib/rbs_infer/parse_cache.rb` — cache compartilhado entre `Analyzer`, `MethodTypeResolver` e `ParamTypeInferrer`.
**Resultado medido**: tempo dos testes de integração reduziu de **3min 18s → 2min 45s** (~17% de ganho).

---

### 3. `.find` linear dentro de loops

**Localização**: `lib/rbs_infer/type_merger.rb:66,144`

Para cada `DefNode` coletado, faz `members.find { |m| m.name == ... }` — O(n) por método. Para uma classe com 50 métodos isso resulta em ~2500 buscas lineares.

**Fix**: Construir um hash antes do loop:

```ruby
members_by_name = members.select { |m| m.kind == :method }.index_by(&:name)
collector.defs.each do |defn|
  member = members_by_name[defn.name.to_s]  # O(1)
end
```

---

### 4. Índice de arquivos inexistente

**Localização**: `lib/rbs_infer/analyzer.rb:176,466`

`@source_files.find { |f| RbsInfer.file_matches_class_path?(f, ...) }` percorre o array inteiro toda vez que precisa localizar um arquivo por nome de classe.

**Fix**: Construir um `Hash` `class_path → file` uma vez no `initialize`:

```ruby
@file_index = {}
@source_files.each do |f|
  # extrai "app/models/user" de "/.../app/models/user.rb"
  key = f.delete_prefix(root + "/").delete_suffix(".rb")
  @file_index[key] = f
end
```

**Implementado**: `lib/rbs_infer/file_index.rb` — índice compartilhado entre `Analyzer`, `MethodTypeResolver` e `ParamTypeInferrer`.
**Resultado medido**: tempo dos testes de integração reduziu de **2min 45s → 2min 35s** (~6% de ganho adicional).

---

### 5. Scan O(D×C) de comentários

**Localização**: `lib/rbs_infer/method_type_resolver.rb:288-298`

Para cada def, varre todos os comentários do arquivo para encontrar anotações próximas. Complexidade O(defs × comments) por arquivo.

**Fix**: Construir um hash `line_number → comment` uma vez por arquivo:

```ruby
comments_by_line = result.comments.index_by { |c| c.location.start_line }
def_visitor.defs.each do |defn|
  def_line = defn.location.start_line
  comment = (def_line - 3..def_line - 1).filter_map { |l| comments_by_line[l] }.last
end
```

---

### 6. DefCollector instanciado duas vezes no mesmo nó

**Localização**: `lib/rbs_infer/type_merger.rb:52,133`

Dois blocos separados constroem um `DefCollector` e chamam `accept()` no mesmo `parsed_target.tree`, fazendo o traversal duas vezes desnecessariamente.

**Fix**: Instanciar uma vez antes dos dois blocos e reutilizar `collector.defs`.

---

## Gargalo descoberto via profiling

Após implementar as otimizações acima, foi feito profiling com `stackprof` que revelou que `RBS::Parser.parse_signature` consumia **44.9% do tempo total**. Os mesmos arquivos `.rbs` (ex: `activerecord-generated.rbs`) eram lidos e parseados pelo `RBS::Parser` a cada chamada de `lookup_rbs_types`, `lookup_inherited_types` e `lookup_gem_rbs_collection_class` — uma vez por classe analisada.

**Fix**: Separar o parsing das declarations (caro) da extração de info por classe (barato) em `RbsParserUtil`, e adicionar `@rbs_declarations_cache` e `@rbs_content_cache` em `RbsTypeLookup` para que cada arquivo `.rbs` seja lido e parseado no máximo uma vez.

**Resultado medido**: tempo dos testes de integração reduziu de **2min 31s → 43s** (~71% de ganho adicional).

---

## Resultado acumulado

| Otimização | Tempo | Ganho |
|---|---|---|
| Baseline | 3min 18s | — |
| ParseCache (Ruby files) | 2min 45s | -33s |
| FileIndex | 2min 35s | -10s |
| CallerFileCache | 2min 31s | -4s |
| RBS declarations cache | 43s | -108s |
| **Total** | **43s** | **-78%** |

---

## Prioridade sugerida (itens pendentes)

| Fix | Esforço | Impacto estimado |
|---|---|---|
| Hash de comentários por linha | baixo | baixo |
| `members_by_name` hash | baixo | baixo |
| DefCollector único | baixo | baixo |

Os itens restantes têm impacto pequeno — o profiling mostrou que os gargalos dominantes já foram resolvidos.
