# Gaps de inferência de tipos no rbs_infer

Auditoria dos padrões Ruby comuns que o rbs_infer não consegue inferir atualmente, afetando a geração de RBS em codebases reais.

---

## 1. Receiver constante — `Const.method()` (Alto impacto)

```ruby
comment = Comment.find(comment_id)
users = User.where(active: true)
post = Post.create(title: "Hello")
```

**Onde falta:** `NodeTypeInferrer` e `IntraClassCallAnalyzer`.

**Causa:** `infer_node_type` só trata `Klass.new`; qualquer outro class method (`find`, `where`, `create`) retorna `nil`. No `IntraClassCallAnalyzer`, `infer_expression_type` não tem branch para `ConstantReadNode`/`ConstantPathNode` como receiver.

**Correção:** Adicionar branch em `infer_expression_type` para receivers constantes usando `resolve_class_method`, que já existe no `MethodTypeResolver` e internamente chama `rbs_definition_resolver.resolve_via_rbs_builder(:singleton, ...)`.

**Referência Steep:** `type_send` em `type_construction.rb` sintetiza o receiver como `singleton(Comment)`, obtém o shape via `Interface::Builder#singleton_shape`, e resolve o return type do método.

---

## 2. Conditional assignments — `||` / `||=` (Alto impacto)

```ruby
@user ||= current_user                    # InstanceVariableOrWriteNode
x = foo || bar                            # OrNode
name = params[:name] || "anonymous"       # OrNode
config = options[:config] ||= default     # LocalVariableOrWriteNode
```

**Onde falta:** Todos os 7 analyzers — nenhum trata `OrNode`, `LocalVariableOrWriteNode` ou `InstanceVariableOrWriteNode`.

**Correção:** 
- `OrNode`: inferir tipo do lado esquerdo; se `nil`, inferir do direito; idealmente o union `(T | U)` sem `nil`.
- `LocalVariableOrWriteNode` / `InstanceVariableOrWriteNode`: tratar como write com o value.
- Adicionar em `NodeTypeInferrer#infer_node_type` e propagar para os analyzers que o incluem.

---

## 3. Ternary / if-expression como valor (Médio-Alto impacto)

```ruby
x = condition ? Foo.new : Bar.new
status = valid? ? :active : :pending
role = admin ? "admin" : "user"
```

**Onde falta:** Todos os analyzers — `IfNode` nunca é matched.

**Correção:** Em `NodeTypeInferrer#infer_node_type`, adicionar:
- Se ambos os branches têm o mesmo tipo → retornar esse tipo.
- Se diferentes → retornar union `(T | U)`.
- Se um lado é `nil` → retornar `T?`.

---

## 4. Operadores de comparação → `bool` (Médio impacto, trivial)

```ruby
def admin? = role == :admin
def valid? = age >= 18
result = name =~ /pattern/
```

**Onde falta:** `NodeTypeInferrer` — operadores `==`, `!=`, `<`, `>`, `<=`, `>=`, `===`, `=~`, `!~` são `CallNode` mas só `.new` é tratado.

**Correção:** Adicionar em `NodeTypeInferrer#infer_node_type`, no branch `CallNode`:
```ruby
when Prism::CallNode
  if node.name == :new && node.receiver
    Analyzer.extract_constant_path(node.receiver)
  elsif %i[== != < > <= >= === !~ =~].include?(node.name)
    "bool"
  end
```

---

## 5. `begin/rescue` como valor (Médio impacto)

```ruby
result = begin
  dangerous_operation
rescue ActiveRecord::RecordNotFound
  nil
rescue StandardError => e
  fallback_value
end
```

**Onde falta:** Todos os analyzers — `BeginNode`/`RescueNode` nunca são tratados como expressão de valor.

**Correção:** Para `BeginNode`, inferir o tipo da última expressão do corpo principal. Se houver `RescueNode`, inferir union com o tipo do rescue clause. Aplicar tanto em `NodeTypeInferrer` quanto em `ReturnTypeResolver` (para métodos cujo corpo é um `begin/rescue`).

---

## 6. Coleta de variáveis locais apenas em nível top-level (Alto impacto)

```ruby
def process
  if valid?
    user = User.find(id)  # ← NÃO coletado
  end
  do_something(user)      # ← user é "untyped"
end

def execute
  case action
  when :create
    result = Creator.new.call  # ← NÃO coletado
  when :update
    result = Updater.new.call  # ← NÃO coletado
  end
  result
end
```

**Onde falta:** `IntraClassCallAnalyzer#collect_local_assignments`, `NewCallCollector`, `ReturnTypeResolver`, `ParamTypeInferrer` — todos iteram apenas `body.body` (statements de primeiro nível).

**Correção:** Usar um visitor recursivo (ou `Prism::Visitor` com `visit_local_variable_write_node`) para coletar **todas** as atribuições dentro do corpo do método, independente do nível de aninhamento. Tomar cuidado com re-atribuições em branches diferentes (usar o primeiro tipo encontrado, ou fazer union se diferem).

---

## 7. Instance variables como argumentos no `ParamTypeInferrer` (Baixo impacto, fácil)

```ruby
process_payment(@order)
notify(@user, @message)
```

**Onde falta:** `ParamTypeInferrer#resolve_arg_value_type` — não tem `InstanceVariableReadNode`.

**Correção:** Adicionar:
```ruby
when Prism::InstanceVariableReadNode
  ivar_name = node.name.to_s.sub(/\A@/, "")
  @local_var_types[ivar_name] || @attr_types[ivar_name] || "untyped"
```

---

## 8. Multi-assignment / destructuring (Baixo-Médio impacto)

```ruby
status, body = fetch_response(url)
first, *rest = items
key, value = pair.split("=", 2)
```

**Onde falta:** Todos os analyzers — `MultiWriteNode` / `MultiTargetNode` nunca é tratado.

**Correção:** Para o caso simples de `a, b = method()` onde o return type do método é conhecido como `[Type1, Type2]` (tuple), mapear cada target ao tipo correspondente. Para o caso genérico, manter `untyped`.

---

## Matriz de cobertura

| Padrão Ruby | NodeTypeInferrer | IntraClassCallAnalyzer | ReturnTypeResolver | ParamTypeInferrer | InitBodyAnalyzer | NewCallCollector | ClassBodyAttrAnalyzer |
|---|---|---|---|---|---|---|---|
| `Const.method()` | ❌ | ❌ | ✅ | parcial | parcial | N/A | parcial |
| `x = a \|\| b` / `\|\|=` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Ternary / if-expr | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Comparações → `bool` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `begin/rescue` valor | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Coleta vars profunda | N/A | ❌ | ❌ | ❌ | N/A | ❌ | N/A |
| `@ivar` como argumento | parcial | N/A | N/A | ❌ | ❌ | ✅ | N/A |
| Multi-assignment | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Method chaining | ❌ | ❌ | ✅ | parcial | ❌ | parcial | ❌ |
| Safe navigation | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Block returns | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

---

## Ordem sugerida de implementação

| # | Gap | Impacto | Esforço | Justificativa |
|---|---|---|---|---|
| 1 | Receiver constante | Alto | Baixo | Já tem `resolve_class_method`. Só falta o branch. |
| 2 | Comparações → `bool` | Médio | Trivial | 3 linhas no `NodeTypeInferrer`. |
| 3 | Coleta de vars profunda | Alto | Baixo-Médio | Trocar iteração flat por visitor recursivo. |
| 4 | Conditional assignments | Alto | Médio | Tratar 3 node types em `NodeTypeInferrer` + propagação. |
| 5 | Ternary / if-expression | Médio-Alto | Médio | Inferir union dos branches. |
| 6 | `@ivar` como argumento | Baixo | Trivial | 3 linhas no `ParamTypeInferrer`. |
| 7 | `begin/rescue` valor | Médio | Médio | Decidir semântica de union com rescue clauses. |
| 8 | Multi-assignment | Baixo-Médio | Médio-Alto | Requer resolução de tuples, escopo limitado. |

---

## Apêndice: cobertura de gems externas — caso CarrierWave

Observado ao executar o plano `carrierwave_user_avatar_upload.md` no `spec/dummy`:

### 1. RBS da gem CarrierWave — resolvido via `gem_rbs_collection` (fork)

`rbs_infer` gera `sig/rbs_infer/app/uploaders/avatar_uploader.rbs` com `class AvatarUploader < CarrierWave::Uploader::Base`. A RBS para a hierarquia da gem (`CarrierWave::Uploader::Base`, `Mount`, `Configuration`, etc.) **vem do fork `felixefelip/gem_rbs_collection`** referenciado em `spec/dummy/rbs_collection.yaml`. Após `bundle exec rbs collection install`, a entrada `carrierwave` aparece em `rbs_collection.lock.yaml` e os tipos passam a resolver normalmente.

**Caminho recomendado para outras gems sem entry no collection:** adicionar manualmente a RBS no fork, ou criar uma stub local em `sig/vendor/<gem>.rbs` com a interface pública usada.

### 2. `mount_uploader` não é reconhecido como override de coluna AR

O `rbs_rails` gera `def avatar: () -> ::String?` (e o setter equivalente) a partir da coluna `users.avatar:string`. Após `mount_uploader :avatar, AvatarUploader`, em runtime esses acessores passam a retornar uma instância de `AvatarUploader`, mas nem `rbs_rails` nem `rbs_infer` ajustam o tipo. Como agora a hierarquia `CarrierWave::*` está resolvida (gap #1), o erro vira concreto no consumidor:

```
app/views/users/show.html.erb:4:29: [error] Type `(::String | nil)` does not have method `url`
app/views/users/avatars/edit.html.erb:17:33: [error] Type `(::String | nil)` does not have method `url`
```

Métodos novos injetados pelo `mount_uploader` também ficam ausentes:

- `avatar` / `avatar=` (override; retornam `AvatarUploader`, aceitam `IO`/`ActionDispatch::Http::UploadedFile`)
- `avatar?` (presence check via uploader)
- `avatar_cache` / `avatar_cache=`
- `remove_avatar` / `remove_avatar=` / `remove_avatar?`
- `remote_avatar_url` / `remote_avatar_url=`
- `write_avatar_identifier`, `store_avatar!`, `store_previous_changes_for_avatar`, etc.

**Possíveis caminhos:**
- Estender `rbs_rails` (ou adicionar um gerador em `RbsInfer::Extensions::Rails`) para detectar `mount_uploader` / `mount_uploaders` no model e reescrever os acessores da coluna correspondente para retornar `<UploaderClass>` em vez de `String?`, além de emitir os auxiliares `*_cache`, `remove_*` e `remote_*_url`.

### 3. Array literal homogêneo inferido como `Array[untyped]`

Para `extension_allowlist`, o corpo é `%w[jpg jpeg gif png webp]`, mas a sig saiu como `def extension_allowlist: () -> Array[untyped]` em vez de `Array[String]`. Provavelmente o `NodeTypeInferrer` não trata `ArrayNode` com `StringNode`/`SymbolNode` literais — gap pequeno, mas reproduzível e isolado.
