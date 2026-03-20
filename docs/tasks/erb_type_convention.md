# ERB Type Convention: RBSInferRailsErbConvention

Gerar classes RBS para cada template ERB seguindo as convenções do Rails, permitindo type checking completo de views e partials com Steep.

## Contexto

### Estado atual

O Steep já suporta arquivos ERB nativamente via `<%# @type self: PostsController %>`, mas essa abordagem tem limitações:

- Exige anotação manual em cada arquivo ERB
- Não tipa as `locals` passadas para partials
- Não permite reutilizar o tipo da view em outros contextos (helpers, decorators)

### Proposta

Criar um módulo `RBSInferRailsErbConvention` que gera uma **classe RBS para cada template ERB**, seguindo as convenções de nomenclatura do Rails. Isso permite:

- Type checking automático de views sem anotações manuais
- Locals tipadas como `attr_reader`
- Inferência de ivars a partir do controller correspondente
- Futuro candidato a gem separada

---

## Convenção de nomenclatura

### Views (não-partials)

Padrão: `ERB<Controller><Action>`

| Arquivo                                | Classe gerada     |
|----------------------------------------|--------------------|
| `app/views/posts/show.html.erb`        | `ERBPostsShow`     |
| `app/views/posts/index.html.erb`       | `ERBPostsIndex`    |
| `app/views/posts/new.html.erb`         | `ERBPostsNew`      |
| `app/views/users/edit.html.erb`        | `ERBUsersEdit`     |
| `app/views/layouts/application.html.erb` | `ERBLayoutsApplication` |

### Partials

Padrão: `ERBPartial<Nome>` (sem o `_` prefix do Rails)

| Arquivo                                  | Classe gerada        |
|------------------------------------------|----------------------|
| `app/views/posts/_form.html.erb`         | `ERBPartialPostsForm`     |
| `app/views/shared/_header.html.erb`      | `ERBPartialSharedHeader`  |
| `app/views/posts/_comment.html.erb`      | `ERBPartialPostsComment`  |

### Namespaced controllers

| Arquivo                                        | Classe gerada              |
|------------------------------------------------|----------------------------|
| `app/views/admin/posts/show.html.erb`          | `ERBAdminPostsShow`        |
| `app/views/admin/posts/_form.html.erb`         | `ERBPartialAdminPostsForm` |

---

## Estrutura da classe gerada

### View (não-partial)

Para `app/views/posts/show.html.erb` com controller:

```ruby
# PostsController
def show
  @post = Post.find(params[:id])
  @comments = @post.comments.recent
end
```

Gerar:

```rbs
class ERBPostsShow
  @post: Post
  @comments: Comment::ActiveRecord_Associations_CollectionProxy

  # Helpers disponíveis via include
  include PostsHelper
  include ApplicationHelper
  include ActionView::Helpers
end
```

As ivars são extraídas do método do controller correspondente (`PostsController#show`), usando o mesmo mecanismo que o `rbs_infer` já usa para controllers.

### Partial com locals

Para `app/views/posts/_form.html.erb` renderizado com:

```ruby
render partial: "posts/form", locals: { post: @post, readonly: false }
```

Gerar:

```rbs
class ERBPartialPostsForm
  attr_reader post: Post
  attr_reader readonly: bool

  include PostsHelper
  include ApplicationHelper
  include ActionView::Helpers
end
```

As locals são inferidas a partir dos **call sites** de `render` no código Ruby (controllers e outras views).

---

## Inferência de locals para partials

### Fontes de informação

1. **`render partial:` com `locals:`** — fonte principal

```ruby
render partial: "posts/form", locals: { post: @post, readonly: false }
# → post: Post, readonly: bool
```

2. **`render @collection`** — Rails passa cada item como local com nome singularizado

```ruby
render @posts  # → post: Post (para _post.html.erb)
```

3. **`render partial:` com `collection:`**

```ruby
render partial: "posts/comment", collection: @comments
# → comment: Comment (para _comment.html.erb)
```

4. **Anotação manual `@rbs`** — fallback quando inferência automática não é possível

```erb
<%# @rbs post: Post %>
<%# @rbs readonly: bool %>
```

### Estratégia de merge

Quando uma partial é renderizada em múltiplos locais com locals diferentes, fazer union dos tipos:

```ruby
# controller A
render "shared/card", locals: { title: "Hello" }
# controller B
render "shared/card", locals: { title: @post.title, subtitle: "Sub" }
```

```rbs
class ERBPartialSharedCard
  attr_reader title: String
  attr_reader subtitle: String?  # opcional (não presente em todos os call sites)
end
```

---

## Associação view ↔ controller

### Convenção Rails

| View path                      | Controller          | Action   |
|--------------------------------|---------------------|----------|
| `views/posts/show.html.erb`   | `PostsController`   | `show`   |
| `views/posts/index.html.erb`  | `PostsController`   | `index`  |
| `views/users/new.html.erb`    | `UsersController`   | `new`    |
| `views/admin/posts/edit.html.erb` | `Admin::PostsController` | `edit` |

### Extração de ivars

Reutilizar o `ClassBodyAttrAnalyzer` / `ClassMemberCollector` existentes no rbs_infer para extrair ivars dos métodos do controller. As ivars atribuídas no action method + `before_action` correspondentes são propagadas para a classe ERB.

---

## Fases de implementação

### Fase 1 — Geração básica de classes para views ✅

- [x] Implementar `RbsInfer::ErbConvention::Generator` (`lib/rbs_infer/erb_convention_generator.rb`)
- [x] Scanner de `app/views/**/*.{html,turbo_stream}.erb`
- [x] Converter path do arquivo → nome da classe (`ERBPostsShow`, `ERBPartialPostsForm`)
- [x] Extrair ivars do controller correspondente (via `Analyzer`, com filtro por `before_action` only/except)
- [x] Gerar RBS com ivars + includes de helpers
- [x] Rake task: `rbs_infer:erb:all` (`lib/tasks/rbs_infer_erb.rake`)
- [x] Makefile target: `make rbs-erb`
- [x] Output em `sig/rbs_infer_erb/` (preserva subpaths: `app/views/posts/show.rbs`)

**Detalhes de implementação:**
- Conversão ERB → Ruby usa `Steep::Source::ErbToRubyCode.convert` (fork do Steep)
- Ivars filtradas por action: mapeia quais métodos escrevem cada ivar, cruza com `before_action` callbacks
- Cache de ivar types por controller (`@controller_ivar_cache`)
- 6 testes de integração cobrindo views, partials e layouts

### Fase 2 — Inferência de locals para partials ✅ (parcial)

- [x] Coletar call sites de `render` em controllers e views (ERB + controllers)
- [x] Extrair `locals:` hash e inferir tipos dos valores (ivars, literais, `Klass.new`)
- [x] Gerar `attr_reader` para cada local
- [ ] Suporte a `collection:` e `render @collection`
- [x] Merge de tipos quando partial é renderizada em múltiplos locais (union com `|`)

**Detalhes de implementação:**
- ERB files convertidos com `ErbToRubyCode.convert` → parse Prism completo → extrai `render partial:` + `locals:`
- Controllers escaneados via Prism AST para `render` calls
- Tipos inferidos: ivars resolvidas pelo contexto do controller, literais (`String`, `Integer`, `bool`, `nil`, etc.), `Klass.new`
- Locals opcionais (presentes em alguns call sites mas não todos) resultam em union type

### Fase 3 — Includes automáticos de helpers ✅

- [x] Detectar helpers associados ao controller (`PostsHelper` para `PostsController`)
- [x] Incluir `ApplicationHelper` em todas as classes
- [x] Incluir `ActionView::Helpers` para métodos como `content_tag`, `link_to`, etc.
- [x] Suporte a `helper_method` do controller (extrai assinaturas do RBS gerado)

**Detalhes de implementação:**
- `detect_helpers` resolve helper pelo nome do controller (ex: `PostsController` → `PostsHelper` se o arquivo existir)
- `ApplicationHelper` incluído em todas as classes se `app/helpers/application_helper.rb` existir
- `ActionView::Helpers` incluído em todas as classes ERB
- `collect_helper_methods` escaneia `ApplicationController` + controller específico para declarações `helper_method :name`
- `extract_helper_method_signatures` parseia o AST com Prism, coleta nomes dos `helper_method`, e extrai assinaturas do RBS gerado pelo Analyzer
- Cache de RBS do controller compartilhado entre `controller_ivar_types` e `extract_helper_method_signatures` via `controller_rbs`
- Métodos helper aparecem como `def name: signature` na classe ERB

### Fase 4 — Integração com Steep (sem alterar ERB files)

O Steep não possui nenhuma opção nativa no Steepfile para associar ERB files a tipos automaticamente. O `self_type` é determinado exclusivamente via annotation `# @type self:` dentro do arquivo, e o Steepfile só oferece `check`, `signature`, `library`, `ignore` e `configure_code_diagnostics`.

A abordagem escolhida é **patch no fork do Steep** (`support_erb/convert_erb_code_into_ruby_before_type_checking`) para injetar o `# @type self:` baseado na convenção de path, dentro do `Source.parse`, antes do parsing de annotations. Assim nenhum arquivo ERB existente precisa ser modificado.

#### Fluxo interno do Steep (ERB)

```
Source.parse(source_code, path:)
  → ErbToRubyCode.convert(source_code)  # strip tags ERB → Ruby puro
  → Parser extrai comments (# @type self: ...)
  → Se encontrar annotation → usa como self_type
  → Senão → default Object
```

#### Implementação no fork Steep

Interceptar em `Source.parse`, após `ErbToRubyCode.convert` e antes do parsing:

```ruby
# Em lib/steep/source.rb, dentro de Source.parse:
if path.to_s.end_with?(".erb")
  source_code = ErbToRubyCode.convert(source_code)
  if (erb_class = erb_self_type_for(path))
    source_code = "# @type self: #{erb_class}\n" + source_code
  end
end
```

A função `erb_self_type_for(path)` segue as convenções Rails:

| Path                                     | self_type                |
|------------------------------------------|--------------------------|
| `app/views/posts/show.html.erb`          | `ERBPostsShow`           |
| `app/views/posts/_form.html.erb`         | `ERBPartialPostsForm`    |
| `app/views/admin/posts/show.html.erb`    | `ERBAdminPostsShow`      |
| `app/views/layouts/application.html.erb` | `ERBLayoutsApplication`  |

#### Tarefas

- [ ] Adicionar `erb_self_type_for(path)` no fork do Steep
- [ ] Injetar annotation no `Source.parse` baseado no path
- [ ] Configuração opt-in (flag no Steepfile ou variável de ambiente) para ativar a convenção
- [ ] Validar que o Steep resolve tipos nas views usando as classes RBS geradas
- [ ] Testes no fork do Steep para a convenção de naming

### Fase 5 — Extração como gem separada (futuro)

- [ ] Extrair `RBSInferRailsErbConvention` para gem `rbs_infer_erb`
- [ ] Dependência obrigatória com `rbs_infer` (usa Analyzer, ClassMemberCollector, SteepBridge, etc.)
- [ ] Documentação e README próprio

---

## Exemplo completo

### Input

`app/views/posts/show.html.erb`:
```erb
<h1><%= @post.title %></h1>

<div class="post-meta">
  <span>Por <%= @post.author_name %></span>
  <%= post_status_badge(@post) %>
</div>

<div class="post-body">
  <%= post_summary(@post) %>
</div>
```

`app/controllers/posts_controller.rb`:
```ruby
class PostsController < ApplicationController
  def show
    @post = Post.find(params[:id])
    @comments = @post.comments.recent
  end
end
```

### Output

`sig/rbs_infer_erb/app/views/posts/show.rbs`:
```rbs
# Generated by rbs_infer (erb_convention)

class ERBPostsShow
  @post: Post
  @comments: Comment::ActiveRecord_Associations_CollectionProxy

  include PostsHelper
  include ApplicationHelper
  include ActionView::Helpers
end
```

---

## Decisões

1. **Naming de layouts**: Manter `ERBLayoutsApplication` por enquanto. Revisitar no futuro se necessário.
2. **Mailers**: Seguir a mesma convenção — `app/views/user_mailer/welcome.html.erb` → `ERBUserMailerWelcome`.
3. **Turbo/Stimulus templates**: `.turbo_stream.erb` segue a mesma convenção de naming.
4. **Conflito de nomes**: Se existir uma classe real no app com o mesmo nome (ex: `ERBPostsShow`), incrementar um sufixo numérico para distinguir (ex: `ERBPostsShow1`).
5. **Performance**: Deixar para o futuro. Otimizações de cache serão consideradas quando necessário.
6. **ERB → Ruby conversion**: Usar `Steep::Source::ErbToRubyCode.convert` do fork do Steep em vez de regex. Preserva line numbers e lida com todos os tipos de tags ERB (`<%= %>`, `<% %>`, `<%# %>`, `<%- -%>`, etc.).
7. **Dependência do Steep fork**: `Gemfile` do rbs_infer aponta para fork local (`/home/felix/workspaces/ruby-workspace/steep_fork/steep`). Gem não foi lançada, sem risco de breaking change.
8. **Sem fallback regex**: Sempre usar `ErbToRubyCode.convert`, sem fallback para regex.

---

## Arquivos implementados

| Arquivo | Descrição |
|---------|-----------|
| `lib/rbs_infer/erb_convention_generator.rb` | Generator principal (Fases 1-3) |
| `lib/tasks/rbs_infer_erb.rake` | Rake task `rbs_infer:erb:all` |
| `lib/rbs_infer/railtie.rb` | Carrega rake task automaticamente no Rails |
| `Makefile` | Target `rbs-erb` |
| `spec/integration/rails_dummy_spec.rb` | 6 testes de integração ERB |
| `spec/expectations/erb/` | 6 snapshots de expectativa |
| `spec/dummy/app/views/posts/` | Views CRUD (index, show, new, edit, _form) |
| `spec/dummy/app/views/layouts/application.html.erb` | Layout padrão |
