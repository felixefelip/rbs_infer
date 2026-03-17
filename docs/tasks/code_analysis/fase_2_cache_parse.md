# Fase 2 — Cachear parse do target file

Parsear o `@target_file` uma única vez e propagar o resultado. Maior impacto em performance com baixo risco.

---

## Contexto

O `@target_file` é lido com `File.read` e parseado com `Prism.parse` em pelo menos 8 lugares distintos durante uma única chamada a `generate_rbs`. Cada parse gera um AST completo, consome memória e CPU desnecessariamente.

**Lugares que parseiam o target file:**
1. `Analyzer#parse_target_class`
2. `Analyzer#extract_optional_init_params`
3. `Analyzer#infer_attr_types_from_initialize`
4. `Analyzer#infer_attr_types_from_class_body`
5. `ParamTypeInferrer#infer_method_param_types`
6. `ReturnTypeResolver#improve_method_return_types`
7. `ReturnTypeResolver#infer_ivar_types`
8. `TypeMerger#resolve_method_return_types_from_attrs`

---

## 2.1 Criar estrutura `ParsedFile` para transportar dados

```ruby
# lib/rbs_infer.rb ou lib/rbs_infer/parsed_file.rb
module RbsInfer
  ParsedFile = Data.define(:result, :source, :comments, :lines) do
    def tree = result.value
  end
end
```

---

## 2.2 Parsear uma vez no `Analyzer#generate_rbs`

**Antes:**
```ruby
def generate_rbs
  return nil unless @target_file && @target_class && File.exist?(@target_file)
  target_members = parse_target_class
  # ... cada método faz seu próprio File.read + Prism.parse
end
```

**Depois:**
```ruby
def generate_rbs
  return nil unless @target_file && @target_class && File.exist?(@target_file)

  source = File.read(@target_file)
  result = Prism.parse(source)
  @parsed_target = ParsedFile.new(
    result: result,
    source: source,
    comments: result.comments,
    lines: source.lines
  )

  target_members = parse_target_class(@parsed_target)
  # ... pass @parsed_target everywhere
end
```

---

## 2.3 Atualizar métodos do Analyzer para receber `parsed_target`

**Métodos a atualizar:**
- `parse_target_class` — receber `parsed_target` em vez de fazer `File.read`
- `extract_optional_init_params` — usar `@parsed_target`
- `infer_attr_types_from_initialize` — usar `@parsed_target`
- `infer_attr_types_from_class_body` — usar `@parsed_target`

Cada um remove o `File.read` + `Prism.parse` e usa `@parsed_target.tree`, `@parsed_target.comments`, `@parsed_target.lines`.

---

## 2.4 Propagar para `ReturnTypeResolver`

**Antes:**
```ruby
def improve_method_return_types(members, attr_types)
  return unless @target_file && File.exist?(@target_file)
  source = File.read(@target_file)
  result = Prism.parse(source)
  # ...
end
```

**Depois:**
```ruby
def improve_method_return_types(members, attr_types, parsed_target:)
  collector = DefCollector.new
  parsed_target.tree.accept(collector)
  # ...
end
```

Mesma mudança para `infer_ivar_types`.

---

## 2.5 Propagar para `ParamTypeInferrer`

Atualizar `infer_method_param_types` para receber `parsed_target:` em vez de parsear internamente.

---

## 2.6 Propagar para `TypeMerger`

Atualizar `resolve_method_return_types_from_attrs` para receber `parsed_target:` em vez de parsear internamente.

---

## Checklist

- [ ] 2.1 — Criar `ParsedFile` Data class
- [ ] 2.2 — Parsear uma vez no `generate_rbs`
- [ ] 2.3 — Atualizar métodos do Analyzer
- [ ] 2.4 — Propagar para `ReturnTypeResolver`
- [ ] 2.5 — Propagar para `ParamTypeInferrer`
- [ ] 2.6 — Propagar para `TypeMerger`
- [ ] Rodar `bundle exec rspec` — 0 failures
- [ ] Commit
