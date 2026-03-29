# Helper Type Convention: `STEEP_MODULE_CONVENTION` para `app/helpers/`

## Contexto

O `ModuleSelfTypeResolver` (Steep fork) injeta automaticamente anotações `@type` em módulos
dentro de `app/models/` ao fazer parsing. Helpers Rails (`app/helpers/`) não são suportados
por dois motivos:

1. **Prefixo hardcoded** — o resolver só reconhece `app/models/`:

   ```ruby
   # module_self_type_resolver.rb:27
   MODELS_PREFIX = "app/models/"
   idx = path_str.index(MODELS_PREFIX)
   return source_code unless idx  # ← helpers retornam aqui
   ```

2. **Exige namespace de 2+ segmentos** — helpers como `PostsHelper` são módulos flat (sem `::`)
   e são descartados na verificação:

   ```ruby
   parts = module_name.split("::")
   return source_code if parts.size < 2  # ← PostsHelper tem 1 segmento → skip
   ```

Por isso, o [posts_helper.rb](../../spec/dummy/app/helpers/posts_helper.rb) tem as anotações
adicionadas **manualmente** em vez de recebê-las automaticamente:

```ruby
module PostsHelper
  # @type self: singleton(PostsHelper) & singleton(ApplicationController)
  # @type instance: PostsHelper & ApplicationController
```

O objetivo desta task é estender o `ModuleSelfTypeResolver` para lidar com helpers
automaticamente, eliminando a necessidade de anotações manuais.

---

## Diferenças em relação a modelos

| Característica | `app/models/` | `app/helpers/` |
|---|---|---|
| Including class derivada de | Namespace (`Post::Notifiable → Post`) | Convenção Rails (`PostsHelper → ApplicationController`) |
| Segmentos no nome | ≥ 2 (`Post::Notifiable`) | 1 (`PostsHelper`) |
| Geralmente concern? | Sim | Não |
| Anotações a injetar | `@type self:` + `@type instance:` (concern) ou só `@type instance:` | `@type instance:` + possivelmente `@type self:` (ver decisão abaixo) |

---

## Including class para helpers

Helpers não têm namespace para derivar a including class. A estratégia é por **convenção Rails**:

```
app/helpers/posts_helper.rb     → PostsHelper     → ApplicationController
app/helpers/users_helper.rb     → UsersHelper     → ApplicationController
app/helpers/application_helper.rb → ApplicationHelper → ApplicationController
```

Todos os helpers usam `ApplicationController` como including class porque:
- É o tipo mais rico disponível para type checking (inclui `url_helpers`, `flash`, etc.)
- Helpers com métodos de view (`content_tag`, `link_to`) recebem esses métodos via `ActionView::Helpers`,
  que deve ser declarado nas assinaturas RBS do `ApplicationController`
- Segue o que foi feito manualmente no `PostsHelper` existente

### Decisão de design: injetar `@type self:`?

O resolver atual injeta `@type self:` apenas em concerns (para cobrir `included do` e
`class_methods do`). Helpers são módulos plain, então pela regra atual receberiam apenas
`@type instance:`.

No entanto, o `PostsHelper` manual tem ambas as anotações. Injetar `@type self:` em helpers
é conservador mas inofensivo — permite que Steep resolva chamadas no contexto singleton do
módulo (pouco comum em helpers, mas não quebra nada).

**Recomendação**: injetar apenas `@type instance:` para ficar consistente com a regra de
módulos plain. Se um helper específico precisar de `@type self:`, ele pode adicioná-la
manualmente (o resolver é idempotente).

---

## Algoritmo proposto

```
dado path + source_code:
  se path terminar em .rb:
    procurar MODELS_PREFIX ou HELPERS_PREFIX no path
    se nenhum → retornar sem modificar

  se HELPERS_PREFIX encontrado:
    relative = path após "app/helpers/" sem ".rb"
    # ex: "posts_helper" → ["posts_helper"] → "PostsHelper"
    module_name = camelize(relative)
    including_class = "ApplicationController"
    # idempotência
    retornar sem modificar se source_code já contém "@type instance: #{module_name}"
    injetar após a linha `module ModuleName`:
      # @type instance: ApplicationController & PostsHelper

  se MODELS_PREFIX encontrado:
    [lógica atual inalterada]
```

---

## Anotação injetada

Para `app/helpers/posts_helper.rb`:

```ruby
module PostsHelper
  # @type instance: ApplicationController & PostsHelper

  def post_status_badge(post)
    ...
  end
end
```

Inserção: imediatamente após a linha `module PostsHelper`, com 2 espaços de indentação
(mesmo padrão de `inject_after_module_line`).

---

## Onde as mudanças ficam

### Steep fork (`lib/steep/source/module_self_type_resolver.rb`)

1. Adicionar constante:
   ```ruby
   HELPERS_PREFIX = "app/helpers/"
   ```

2. Em `annotate`, após a verificação de `.rb`, checar ambos os prefixos e ramificar:
   ```ruby
   helpers_idx = path_str.index(HELPERS_PREFIX)
   return annotate_helper(path_str, source_code, helpers_idx) if helpers_idx

   models_idx = path_str.index(MODELS_PREFIX)
   return source_code unless models_idx
   # [lógica atual para models]
   ```

3. Adicionar método privado `annotate_helper(path_str, source_code, idx)`:
   - Deriva `module_name` do filename (sem path, sem `.rb`, camelizado)
   - `including_class = "ApplicationController"`
   - Chama `inject_after_module_line(source_code, module_name, including_class)`

### `rbs_infer` (`lib/rbs_infer/analyzer.rb`)

Nenhuma mudança necessária se o `Analyzer` já chama `ModuleSelfTypeResolver.annotate`
antes do `Prism.parse`. A lógica nova no resolver será aplicada automaticamente.

Verificar que o `Analyzer` processa helpers (pode estar restrito a `app/models/`).

---

## Testes (Steep fork)

Adicionar casos em `test/source/module_self_type_resolver_test.rb`:

| Cenário | Resultado esperado |
|---|---|
| `app/helpers/posts_helper.rb` — módulo plain | `@type instance: ApplicationController & PostsHelper` injetado após `module PostsHelper` |
| `app/helpers/application_helper.rb` | `@type instance: ApplicationController & ApplicationHelper` injetado |
| Helper já anotado | Sem mudança (idempotente) |
| `app/helpers/posts_helper.rb` com `extend ActiveSupport::Concern` | Tratar como concern: injetar `@type self:` + `@type instance:` |
| Path sem `app/helpers/` nem `app/models/` | Sem mudança |

---

## Atualização de docs

- Atualizar [module_type_inference.md](../guides/module_type_inference.md):
  - Adicionar `app/helpers/` na tabela de suporte
  - Documentar que a including class para helpers é sempre `ApplicationController`
  - Atualizar a tabela de "Known limitations" (remover helpers como limitação)
  - Atualizar o diagrama de fluxo

---

## Trabalho restante

- [ ] Adicionar `HELPERS_PREFIX` e método `annotate_helper` no fork do Steep
- [ ] Garantir que `rbs_infer/analyzer.rb` processa arquivos em `app/helpers/`
- [ ] Adicionar testes no fork do Steep para helpers
- [ ] Remover anotações manuais de `spec/dummy/app/helpers/posts_helper.rb` e validar que as anotações são injetadas automaticamente
- [ ] Atualizar `docs/guides/module_type_inference.md`
