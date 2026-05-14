# Visão geral: papel das gems do ecossistema RBS

Este projeto envolve várias gems do ecossistema RBS, cada uma com escopo bem delimitado. O objetivo deste documento é descrever **quem faz o quê**, para evitar duplicação de trabalho e indicar onde adicionar novas features.

---

## TL;DR — tabela de papéis

| Gem | Função primária | Fonte de evidência | Output |
|---|---|---|---|
| **rbs** | Núcleo do ecossistema: parser, type model, runtime API | n/a — é a base | Define formato `.rbs` |
| **rbs_collection** | Distribuição de assinaturas para gems de terceiros | repositório `ruby/gem_rbs_collection` | `.gem_rbs_collection/` |
| **steep** | Type checker estático | `.rbs` + código `.rb` | Diagnósticos |
| **steep (fork)** | Type checker + **consumo de pré-condições inferidas** (novo, Phase 1) | Tudo do acima + `sig/generated/.steep_contracts.yml` | Diagnósticos + narrow cross-method |
| **rbs_rails** | Gera `.rbs` para modelos AR, helpers, controllers de Rails | Boot do Rails (schema, validators, helpers) | `sig/rbs_rails/**/*.rbs` |
| **rbs_rails (fork)** | Igual ao acima + tighten por validations (presence, etc.) — gap aberto | Idem | Idem |
| **rbs_infer** | Inferência de `.rbs` a partir de **análise estática do código Ruby** | AST (via Prism) + `.rbs` existentes (via Steep) | `sig/generated/**/*.rbs` |

A regra mental: **cada gem usa só a fonte de evidência que naturalmente possui**. Schema é responsabilidade de quem boota Rails; AST é responsabilidade de quem parseia o código; narrow é responsabilidade de quem typecheka.

---

## 1. `rbs` — o núcleo

Mantido em `ruby/rbs`. Define a gramática `.rbs`, parser, modelo interno de tipos (`RBS::TypeName`, `RBS::AST::Members`, etc.) e a runtime API (`RBS::Environment`, `RBS::DefinitionBuilder`).

Tudo que está abaixo nesta lista **depende do `rbs`** como biblioteca. As outras gems não reescrevem parser nem modelo de tipo — usam o do `rbs`.

Geralmente não precisamos mexer aqui. Quando precisamos, é por algum bug de parsing de RBS ou suporte a sintaxe nova.

---

## 2. `rbs_collection` — biblioteca de assinaturas para gems de terceiros

Não é uma gem que se "instala" sozinha — é o **mecanismo do próprio `rbs` CLI** que sabe baixar e indexar `.rbs` de gems para as quais não há `sig/` no próprio gem.

**Como funciona:**

- O repositório `ruby/gem_rbs_collection` é um monorepo público com `.rbs` curados por gem (`activerecord`, `nokogiri`, `prism`, etc.).
- No projeto, você roda `rbs collection install`, que lê:
  - `rbs_collection.yaml` (config, lista repositórios e que gems vêm de onde)
  - `Gemfile.lock` (versões reais de cada gem)
- Resolve qual versão `.rbs` casa com cada gem e baixa para `.gem_rbs_collection/` (local, gitignored em geral) ou um diretório configurado.
- Cria `rbs_collection.lock.yaml` que pina versões.

**No `order_factory`:** `rbs_collection.yaml` + `rbs_collection.lock.yaml` na raiz. O `Steepfile` cita o collection para o checker enxergar tudo. Quando uma gem nova é adicionada/atualizada, roda-se `rbs collection update` para sincronizar.

**Quando mexer:**

- Para colaborar com a comunidade: PR no `ruby/gem_rbs_collection` upstream.
- Para uso interno: o user mantém um fork local em `/Users/felipepessoa/workspaces/gem_rbs_collection` referenciado pelo `rbs_collection.yaml`.

---

## 3. `steep` — type checker

Mantido em `soutaro/steep`. Lê `.rbs` (do projeto, do collection, da stdlib) + `.rb` do projeto, sintetiza tipos de cada expressão, e reporta diagnósticos.

Fork em `felixefelip/steep` (branch `rbs_infer`) adiciona:

- **ERB type-checking** via convenção de view path (PR #3, já merged).
- **ModuleSelfTypeResolver** para `app/controllers/concerns/`, `app/helpers/`, etc. (#3).
- **`Steep::Contracts`** + narrow cross-method (Phase 1 de `felixefelip/steep#2`, branch `feat/contracts-phase1`):
  - Lê `sig/generated/.steep_contracts.yml`.
  - Refina o tipo de `self.X` no corpo do método quando há `not_nil(self.X)` no contrato.
  - Emite `Ruby::PreconditionUnsatisfied` quando o chamador não satisfaz a pré-condição.

**Quem produz o sidecar:** decidiu-se que **o próprio Steep** (em fases posteriores), via análise interna do call graph. Não rbs_infer (que tem outro escopo).

---

## 4. `rbs_rails` — geração de `.rbs` para Rails

Mantido em `pocke/rbs_rails`. Fork do user em `felixefelip/rbs_rails`. Boota Rails (precisa de ambiente real funcionando) e gera `.rbs` para:

- Modelos ActiveRecord: getters/setters/scopes baseados em `columns_hash`.
- Path helpers, route helpers.
- Generators do Rails (controllers, etc.).

**Faz hoje:**

- Lê `column.null` para decidir entre `String` e `String?` (`lib/rbs_rails/active_record.rb:547`).
- Mapeia tipos SQL para classes Ruby (`Decimal` → `BigDecimal`, etc.).
- Trata `enum`, scopes, associations.

**Gap conhecido (próximo trabalho candidato no fork):**

- **Não considera validations.** Coluna `null: true` + `validates :name, presence: true` ainda sai como `String?` na RBS gerada. Deveria virar `String`. Implementação: consultar `klass.validators_on(:attr)` por `ActiveModel::Validations::PresenceValidator` e estreitar quando presente.

**Não cabe nele:**

- Análise de código Ruby fora dos modelos (helpers de método arbitrário, services, POROs) — isso é `rbs_infer`.

---

## 5. `rbs_infer` — inferência por análise estática

Este projeto. Não boota Rails (nem precisa). Trabalha em cima de AST via Prism e consulta `.rbs` existentes via Steep (`SteepBridge`).

**Faz hoje:**

- Tipos de parâmetros de `initialize` a partir de call-sites (`User.new(name: "Jo")` → `name: String`).
- Tipos de `attr_*` a partir de atribuições e usos.
- Return types de métodos a partir do corpo (literais, constantes, calls, forwarding, collection ops).
- Element types de Array/Hash a partir de operações (`array << Item.new` → `Array[Item]`).
- Resolução cross-class via `RbsTypeLookup` / `MethodTypeResolver`, usando inclusive `.rbs` gerados por `rbs_rails` e pelo `gem_rbs_collection`.
- Extensões Rails-aware: gerador `enumerize`, custom application_controller/action_view_context, ERB convention, carrierwave uploader.

**Não faz (e nem deve fazer):**

- Ler `db/schema.rb` ou bootar AR — é território de `rbs_rails`.
- Avaliar validations — `rbs_rails`.
- Inferir pré-condições de método (not_nil cross-method) — `steep` fork (Phase 2 futura).

**Gaps abertos:** ver [`type_inference_gaps.md`](type_inference_gaps.md) — patterns ainda não suportados (const receivers, `||`, ternários, comparações, etc.).

---

## Fluxo de produção/consumo

Diagrama da pipeline real no `order_factory`:

```
                    ┌───────────────────┐
                    │  ruby/rbs (gem)   │  ← base, parser, modelo
                    └───────────────────┘
                              │
            ┌─────────────────┼──────────────────┐
            │                 │                  │
            ▼                 ▼                  ▼
   ┌─────────────────┐ ┌──────────────┐ ┌────────────────┐
   │ gem_rbs_collec. │ │  rbs_rails   │ │   rbs_infer    │
   │  (third-party)  │ │ (boota Rails)│ │  (AST estático) │
   └─────────────────┘ └──────────────┘ └────────────────┘
            │                 │                  │
            │       gera      │       gera       │
            │                 │                  │
            ▼                 ▼                  ▼
   .gem_rbs_collection/  sig/rbs_rails/    sig/generated/
            │                 │                  │
            └─────────┬───────┴──────────────────┘
                      │
                      ▼
              ┌──────────────┐
              │    steep     │  ← consome tudo
              │   (fork)     │
              └──────────────┘
                      │
                      ▼
            [futuramente, Phase 2]
              sig/generated/.steep_contracts.yml
                      │
                      └──→ re-consumido pelo próprio steep
```

**Resumindo a ordem de execução no dev:**

1. `bundle install` — gems instaladas.
2. `rbs collection install` — `.gem_rbs_collection/` populado.
3. `rake rbs_rails:all` — `sig/rbs_rails/` regenerado (precisa de Rails bootando).
4. `bundle exec rbs_infer app/ --output` — `sig/generated/` regenerado (não precisa de Rails).
5. `rake rbs_infer:enumerize:all` / `rbs_infer:rails_custom:all` / `rbs_infer:erb:all` — saídas das extensions.
6. (Futuro) Steep gera/atualiza `sig/generated/.steep_contracts.yml` no próximo typecheck.
7. `steep check` — valida tudo.

---

## Decisões arquiteturais consolidadas

- **Schema/validations → `rbs_rails`**, não rbs_infer. Quem boota Rails é quem consulta o ORM.
- **Inferência de pré-condições (`not_nil` cross-method) → `steep` fork**, não rbs_infer. Quem typecheka é quem coleta as obrigações faltantes.
- **Inferência de tipo a partir de código Ruby genérico → `rbs_infer`**. Quem parseia AST é quem deduz forma de chamada/uso.
- **Sidecar de pré-condições é detalhe interno do Steep fork**, não contrato cross-gem. Pode virar cache binário, in-memory, ou ficar como YAML — decisão do Steep.

Cada gem tem **uma única fonte de evidência** que naturalmente possui. Não duplica trabalho que pertence ao vizinho.
