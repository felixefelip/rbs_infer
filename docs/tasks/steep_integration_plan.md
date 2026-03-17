# Plano: Integrar Steep como oracle de tipos de expressões

O rbs_infer tem como meta cobrir Ruby idiomático de forma abrangente e a longo prazo. Em vez de implementar manualmente cada padrão de expressão Ruby (ternários, `||`, `begin/rescue`, method chains, etc.), vamos usar o `TypeConstruction` do Steep como oracle para resolver tipos de expressões, mantendo o rbs_infer responsável pela inferência caller-side e geração de RBS.

---

## Contexto: por que o Steep

O rbs_infer hoje resolve tipos de expressões com ~200 linhas espalhadas entre `NodeTypeInferrer`, `IntraClassCallAnalyzer`, `ReturnTypeResolver`, etc. Há pelo menos 8 gaps conhecidos (ver `type_inference_gaps.md`), e qualquer padrão Ruby novo que surgir exigiria implementação manual.

O Steep já implementa inferência completa de expressões Ruby no `TypeConstruction#synthesize` (~5000 LOC). Prova de conceito validada:

```
Comment.find(comment_id)   → ::Comment
User.where(...).first      → (::User | nil)
y || "default"             → ::String
cond ? :yes : :no          → ::Symbol
x > 10                     → bool
comment.body.blank?        → bool
```

Performance verificada: setup one-time ~1.4s, **~4ms por arquivo** após setup. Memória: ~170MB.

A compatibilidade de parser é garantida pelo `Prism::Translation::Parser`, que produz `Parser::AST::Node` compatíveis com o Steep.

### O que o Steep NÃO resolve

O Steep precisa de RBS para tipar parâmetros de métodos. Sem assinatura RBS, parâmetros de métodos privados ficam `untyped`. O rbs_infer continuará necessário para:

- Inferência **caller-side** de tipos de parâmetros (o que `IntraClassCallAnalyzer` faz)
- **Geração de assinaturas RBS** a partir do código fonte
- Análise **cross-file** de call sites
- Inferência de **attrs** via `initialize`

---

## Fase 1 — `SteepBridge`: adapter isolado ✅ CONCLUÍDA

Criar `lib/rbs_infer/steep_bridge.rb` que encapsula toda a interação com o Steep:

```ruby
module RbsInfer
  class SteepBridge
    def initialize(rbs_paths: [], gem_collection_paths: [])
      # Carrega env RBS + monta subtyping checker (one-time)
    end

    # Retorna { "var_name" => "Type", ... } para variáveis locais no método
    def local_var_types(source_code, method_name:, class_name: nil)
    end

    # Retorna o tipo de uma expressão arbitrária dado um contexto
    def expression_type(source_code, line:, column:)
    end

    # Retorna { method_name => return_type } para todos os métodos de um arquivo
    def method_return_types(source_code)
    end
  end
end
```

### Tarefas

1. **Criar `SteepBridge`** com lazy initialization do ambiente Steep (só carrega quando necessário).
2. **Usar `Steep::Source.parse`** (que usa `Parser::Ruby33` internamente) para parsear o código.
3. **Chamar `TypeCheckService.type_check`** e iterar `typing.each_typing` para coletar tipos.
4. **Mapear tipos Steep para strings RBS** (`::Comment` → `"Comment"`, `(::User | nil)` → `"User?"`).
5. **Cachear** o ambiente RBS e o subtyping checker (são os custos pesados; parse+check por arquivo é barato).
6. **Testes unitários** para o bridge isolado, validando os 8 gaps conhecidos.

---

## Fase 2 — Substituir `NodeTypeInferrer` + `infer_expression_type` no pipeline ✅ CONCLUÍDA

Integrar o `SteepBridge` como fonte primária de tipos de expressões, substituindo as implementações manuais.

### 2a. `IntraClassCallAnalyzer` — variáveis locais

Substituir `collect_local_assignments` + `infer_expression_type` + `resolve_value_type` pelo Steep:

```ruby
# Antes (manual, com gaps):
collect_local_assignments(defn)  # só top-level, sem ||, ternário, etc.
type = resolve_value_type(arg)   # fallback "untyped" para muitos padrões

# Depois (via Steep):
typing = @steep_bridge.type_check(source_code)
# Steep já resolve TODAS as variáveis locais — incluindo as dentro de if/case/begin
```

Isso elimina de uma vez os gaps 1–6 (receiver constante, `||`, ternário, comparações, begin/rescue, coleta profunda de vars) no `IntraClassCallAnalyzer`.

### 2b. `ReturnTypeResolver` — return types

O `ReturnTypeResolver` já trata vários padrões (chains, safe nav, blocks). Usar Steep como **primeiro recurso**, mantendo a lógica atual como fallback:

```ruby
def resolve_return_type(method_name, source, ...)
  # Tentar via Steep primeiro
  steep_type = @steep_bridge.method_return_types(source)[method_name]
  return steep_type if steep_type && steep_type != "untyped"

  # Fallback: lógica atual do ReturnTypeResolver
  resolve_from_body(...)
end
```

### 2c. `NewCallCollector` e `ParamTypeInferrer`

Onde esses analyzers precisam do tipo de uma expressão para inferir o tipo de um argumento passado, usar o Steep em vez de `resolve_value_type` / `infer_node_type`.

### Tarefas

1. Propagar `SteepBridge` como dependência opcional no `Analyzer` (construído uma vez, compartilhado).
2. Integrar no `IntraClassCallAnalyzer`: usar Steep para tipos de variáveis locais.
3. Integrar no `ReturnTypeResolver`: Steep como primeiro recurso para return types.
4. Integrar no `NewCallCollector` e `ParamTypeInferrer`: Steep para tipos de argumentos.
5. Manter toda a lógica atual como **fallback** (quando Steep não está disponível ou retorna `untyped`).
6. Testes de integração validando que os mesmos RBS continuam sendo gerados (não-regressão).

---

## Fase 3 — Remover código manual redundante ✅ CONCLUÍDA

Após validar que o Steep cobre todos os casos, código de inferência manual redundante foi removido/simplificado:

1. **`NodeTypeInferrer`** — NÃO removido (ainda usado por 7 classes: InitializeBodyAnalyzer, TypeMerger, ClassBodyAttrAnalyzer, ClassMemberCollector, MethodTypeResolver, etc.). Removido apenas dos analyzers que agora usam Steep diretamente.
2. **`IntraClassCallAnalyzer`** — Removido `include NodeTypeInferrer` e `infer_expression_type`. `resolve_value_type` tornado autocontido (literais inline, Klass.new, attr_types). `collect_local_assignments` simplificado como fallback (não sobrescreve tipos do Steep).
3. **`ReturnTypeResolver`** — Remoção massiva (~120 LOC): removidos `include NodeTypeInferrer`, `infer_ivar_value_type` (75+ linhas de resolução de chains), `resolve_chain_type`, `resolve_on_type`, `infer_block_return_type`, `collect_local_var_type`. Pipeline simplificado: known_return_types → Steep (sem análise manual do body). `infer_ivar_types` usa `SteepBridge#ivar_write_types` como primeiro recurso. Adicionado `basic_value_type` como fallback mínimo.
4. **`NewCallCollector`** — MANTIDO como está. Opera em caller files (CallerFileAnalyzer) sem integração com Steep. Remover `resolve_receiver_type`/`resolve_chain_type` exigiria adicionar Steep ao CallerFileAnalyzer — seria adição de complexidade, não remoção.
5. **`RbsDefinitionResolver`** — Simplificado: removido `build_rbs_definition_builder` (50 LOC de carregamento de RBS duplicado). Agora delega para `SteepBridge.definition_builder` (cache compartilhado class-level), eliminando ~1s de loading e ~50MB de memória duplicada.

### Critério para remoção

Só remover código manual quando testes de integração confirmam que o Steep produz resultado igual ou melhor.

---

## Fase 4 — Steep como dependência obrigatória ✅ CONCLUÍDA

O Steep passa a ser dependência direta do rbs_infer. Não há modo "lite" sem Steep — isso evita duplicação de código e lógica de fallback.

```ruby
# rbs_infer.gemspec
spec.add_dependency "steep", ">= 1.9"
```

Justificativa: manter o Steep como opcional exigiria preservar toda a lógica manual de inferência em paralelo (os ~200 LOC de `NodeTypeInferrer`, `infer_expression_type`, `resolve_chain_type`, etc.) para o caso "sem Steep". Isso resultaria em:

- **Código duplicado** — dois caminhos de inferência para manter e testar.
- **Divergência inevitável** — bugs corrigidos num caminho não são propagados ao outro.
- **Complexidade de branching** — `if SteepBridge.available? ... else ...` espalhado pelo pipeline.

Como o rbs_infer é uma ferramenta de geração offline (não é usada em runtime da aplicação), o peso das dependências do Steep é aceitável. Quem instala o rbs_infer já aceita ter o ecossistema RBS no ambiente de desenvolvimento.

---

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| API interna do Steep muda | Isolar toda interação em `SteepBridge`. Uma única classe para atualizar. |
| Steep não está no Gemfile do projeto | Dependência opcional com fallback. |
| Performance em projetos com muitos arquivos | O setup é one-time; por arquivo custa ~4ms. Para 500 arquivos ~2s. |
| Memória (+170MB) | Aceitável para ferramenta de geração offline. Documentar. |
| Versão do Steep vs RBS | Alinhar requisito de versão. Ambos devem usar RBS 4.x. |
| Steep precisa de RBS para inferir tipos | É circular, mas na prática o rbs_infer gera RBS incrementalmente — gems e stdlib já têm RBS via `gem_rbs_collection`. |

---

## Resumo da divisão de responsabilidades

```
┌─────────────────────────────────────────────────┐
│                   rbs_infer                      │
│                                                  │
│  ┌────────────────┐     ┌─────────────────────┐  │
│  │  SteepBridge   │     │  Lógica própria     │  │
│  │                │     │                     │  │
│  │ • Tipos de     │     │ • Caller-side       │  │
│  │   expressões   │     │   param inference   │  │
│  │ • Return types │     │ • Cross-file        │  │
│  │ • Var locals   │     │   call analysis     │  │
│  │ • Chains       │     │ • Attr inference    │  │
│  │ • Ternários    │     │   via initialize    │  │
│  │ • ||, begin    │     │ • RBS generation    │  │
│  │ • Comparações  │     │ • Annotation parse  │  │
│  └───────┬────────┘     └──────────┬──────────┘  │
│          │                         │             │
│          └──────────┬──────────────┘             │
│                     │                            │
│              ┌──────▼──────┐                     │
│              │ RBS Output  │                     │
│              │ (.rbs file) │                     │
│              └─────────────┘                     │
└─────────────────────────────────────────────────┘
```
