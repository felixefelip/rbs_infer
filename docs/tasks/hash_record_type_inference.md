# Hash Record Type Inference

Inferir tipos Record do RBS (`{ key: Type }`) para hash literals, em vez do genérico `Hash[Symbol, untyped]`.

## Contexto

### Estado atual

| Local | Resultado |
|-------|-----------|
| `NodeTypeInferrer.infer_hash_type` | `Hash[Symbol, untyped]` (só key type) |
| `InitializeBodyAnalyzer#infer_hash_types` | `Hash[Symbol, String \| Integer]` (union de valores) |
| Steep (via SteepBridge) | `Hash[Symbol, (String \| Integer)]` (union de valores) |

Nenhum produz Record types. O RBS suporta nativamente:

```rbs
{ foo: String, baz: Integer, nested: { a: Integer, b: Integer }, comment: Comment }
{ foo: String, ?other_comment: Comment }  # key opcional com prefixo ?
```

### Por que Record types?

Record types preservam a informação estrutural do hash — quais keys existem e qual o tipo de cada valor individualmente. Isso permite que ferramentas como Steep validem acessos a keys específicas e detectem erros de tipo por key.

---

## Fase 1 — Record types para hash literals estáticos

### Objetivo

Quando um método retorna um hash literal com todas as keys sendo Symbol, gerar record type no RBS.

```ruby
# Input
def dummy_hash
  { foo: "bar", baz: 42, nested: { a: 1, b: 2 }, comment: Comment.new }
end
```

```rbs
# Antes:  def dummy_hash: () -> Hash[Symbol, untyped]
# Depois: def dummy_hash: () -> { foo: String, baz: Integer, nested: { a: Integer, b: Integer }, comment: Comment }
```

### Regras

| Condição | Tipo gerado |
|----------|-------------|
| Todas as keys são Symbol, sem splat | Record type `{ key: Type, ... }` |
| Keys mistas (Symbol + String + Integer) | `Hash[untyped, untyped]` (fallback) |
| Hash com `**splat` (`AssocSplatNode`) | `Hash[Symbol, untyped]` (fallback) |
| Hash vazio `{}` | `Hash[untyped, untyped]` |

### Inferência recursiva de valores

Para cada valor no hash, inferir o tipo usando a lógica existente do `NodeTypeInferrer`:

| Valor | Tipo inferido |
|-------|---------------|
| `"bar"` | `String` |
| `42` | `Integer` |
| `{ a: 1, b: 2 }` | `{ a: Integer, b: Integer }` (recursivo) |
| `Comment.new` | `Comment` |
| `true` / `false` | `bool` |
| `nil` | `nil` |
| `:symbol` | `Symbol` |
| Expressão complexa / desconhecida | `untyped` |

### Pontos de alteração

1. **`NodeTypeInferrer.infer_hash_type`** — lógica principal: detectar se todas as keys são Symbol e gerar record type com inferência recursiva de valores
2. **`InitializeBodyAnalyzer#infer_hash_types`** — alinhar para gerar record type quando aplicável (ivars/self assignments)
3. **Consumidores automáticos** — `ReturnTypeResolver`, `IntraClassCallAnalyzer`, `NewCallCollector` já chamam `infer_hash_type`, ganham o benefício sem alteração

### Testes

- [ ] Hash com Symbol keys → record type
- [ ] Hash com keys mistas → fallback `Hash[untyped, untyped]`
- [ ] Hash com splat → fallback `Hash[Symbol, untyped]`
- [ ] Hash vazio → `Hash[untyped, untyped]`
- [ ] Hash aninhado → record recursivo
- [ ] Valores de diferentes tipos (literais, constantes, `Klass.new`)
- [ ] Integração: `dummy_hash` no dummy Rails app gera record type no `.rbs`

---

## Fase 2 — Rastreamento de mutações (`[]=`)

### Objetivo

Quando um hash (record) sofre `hash[:new_key] = value`, expandir o record type com keys opcionais.

```ruby
def test_dummy_hash
  dummy_hash[:other_comment] = Comment.new(body: "Another comment")
end
```

A key `:other_comment` não faz parte do literal original de `dummy_hash`, mas é adicionada dinamicamente. O tipo do hash expandido seria:

```rbs
{ foo: String, baz: Integer, nested: { a: Integer, b: Integer }, comment: Comment, ?other_comment: Comment }
```

### Desafios

- **Resolução de origem:** precisa saber que `dummy_hash` retorna um record type específico para mergar as novas keys
- **Análise de fluxo:** rastrear chamadas `[]=` na variável/retorno do método
- **Escopo:** mutações podem acontecer em métodos diferentes do que criou o hash
- **Edge cases:** hash passado como argumento, reatribuído, condicional (`if` com `[]=` em um branch)

### Abordagem proposta

1. Quando encontrar `expr[:sym_key] = value` onde `expr` resolve para um record type:
   - Inferir o tipo do `value`
   - Adicionar `?sym_key: Type` como key opcional ao record
2. Limitar o escopo à análise intra-método (mesmo método que tem o `[]=`)
3. Para mutações cross-method, manter o record type original sem expansão

### Pontos de alteração

- `IntraClassCallAnalyzer` ou novo visitor para coletar chamadas `[]=` em hashes
- `TypeMerger` — lógica para mergar keys opcionais em record types existentes
- `ReturnTypeResolver` — considerar mutações ao resolver tipo final

### Testes

- [ ] Hash local mutado com `[]=` → record expandido com key opcional
- [ ] Hash de método mutado no mesmo método → record expandido
- [ ] Múltiplas mutações `[]=` no mesmo hash
- [ ] Mutação cross-method → não expande (fallback)
- [ ] Mutação com key não-Symbol → fallback para Hash genérico

---

## Status

- [ ] Fase 1 — Record types estáticos
- [ ] Fase 2 — Rastreamento de mutações
