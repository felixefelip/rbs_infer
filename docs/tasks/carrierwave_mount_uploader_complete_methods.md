# Task: cobertura completa dos métodos injetados por `mount_uploader` / `mount_uploaders`

Expandir o gerador `RbsInfer::Extensions::CarrierWave::Generator` para cobrir todos os métodos que CarrierWave 3.x injeta no model. A versão atual cobre só os ~14 acessores mais óbvios; faltam ~10 métodos por uploader montado, e há **um método inexistente sendo emitido** que precisa ser removido.

Referência canônica: `carrierwave-3.1.2/lib/carrierwave/mount.rb` (módulo `CarrierWave::Mount`) + `carrierwave/orm/activerecord.rb` (módulo `CarrierWave::ActiveRecord`) + `carrierwave/validations/active_model.rb` (módulo `CarrierWave::Validations::ActiveModel`).

---

## Inventário: o que `mount_uploader` (singular) injeta

Para `mount_uploader :avatar, AvatarUploader` num `ApplicationRecord`, três módulos anônimos são incluídos no model, mais um `class_eval` direto na classe. O conjunto final de métodos (todos com `<col>` = `avatar`):

### Do bloco `mount_uploader` (mount.rb:139-188) — singular-only

| Método | Retorno em runtime | Notas |
|---|---|---|
| `avatar` | `AvatarUploader` (uploader[0] ou `blank_uploader`) | nunca `nil` |
| `avatar=(new_file)` | resultado do `.cache([new_file])` | aceita IO / UploadedFile / String / nil |
| `avatar_url(*args)` | `String` ou `nil` (delega para `avatar.url(*args)`) | **faltando hoje** |
| `avatar_cache` | `String?` (primeiro cache name) | |
| `avatar_cache=(cache_name)` | atribui | |
| `remote_avatar_url` | `String?` (primeiro remote URL) | |
| `remote_avatar_url=(url)` | atribui | |
| `remote_avatar_request_header=(header)` | `Hash[String, String]` ou similar | **faltando hoje** |
| `avatar_identifier` | `String?` | **faltando hoje** |
| `avatar_integrity_error` | `Exception?` (`avatar_integrity_errors.last`) | **faltando hoje** |
| `avatar_processing_error` | `Exception?` | **faltando hoje** |
| `avatar_download_error` | `Exception?` | **faltando hoje** |

### Do `mount_base` (mount.rb:343-402) — singular e plural

| Método | Retorno | Notas |
|---|---|---|
| `avatar?` | `bool` (presence via mounter) | |
| `remove_avatar` | `bool` ou `String` (estado do checkbox) | |
| `remove_avatar=(value)` | atribui | aceita `bool`/`String` |
| `remove_avatar?` | `bool` | |
| `remove_avatar!` | nil/void (chama `_mounter.remove!`) | |
| `store_avatar!` | void | |
| `avatar_integrity_errors` | `Array[Exception]` | **faltando hoje** |
| `avatar_processing_errors` | `Array[Exception]` | **faltando hoje** |
| `avatar_download_errors` | `Array[Exception]` | **faltando hoje** |
| `write_avatar_identifier` | void | |
| `mark_remove_avatar_false` | void | **faltando hoje** |
| `reset_previous_changes_for_avatar` | void | **faltando hoje** |
| `remove_previously_stored_avatar` | void | **faltando hoje** |
| `remove_rolled_back_avatar` | void | **faltando hoje** |

### Do `class_eval` direto (mount.rb:336-339)

```ruby
def #{column}; super; end
def #{column}=(new_file); super; end
```

Apenas wrappers que chamam `super` — assinatura coincide com o que está no módulo, então não muda a RBS.

### Do `CarrierWave::ActiveRecord` (orm/activerecord.rb)

- Sobrescreve `reload(*)` (mantém assinatura original).
- Sobrescreve `initialize_dup` (mantém assinatura original).
- Sobrescreve `write_<col>_identifier` apenas para checar `has_attribute?` (mantém assinatura).
- Registra `read_uploader` / `write_uploader` como public aliases de `read_attribute` / `write_attribute` — métodos da extensão `CarrierWave::Mount::Extension`.

Esses não introduzem novos métodos visíveis ao usuário além de `read_uploader` / `write_uploader`.

### Do `CarrierWave::Validations::ActiveModel`

Métodos de classe (não dependem de coluna):
- `validates_integrity_of(*attr_names)`
- `validates_processing_of(*attr_names)`
- `validates_download_of(*attr_names)`

Esses já estão (ou deveriam estar) no fork do `gem_rbs_collection` como parte do `CarrierWave::Validations::ActiveModel::HelperMethods`.

---

## Bug a corrigir no gerador atual

```ruby
# generator.rb:140 — método inexistente
"  def store_previous_changes_for_#{attr}: () -> void"
```

`store_previous_changes_for_<col>` **não existe em CarrierWave 3.1.2**. Foi inferido por similaridade com `reset_previous_changes_for_<col>` e `remove_previously_stored_<col>` (ambos reais). Remover.

---

## Inventário: o que `mount_uploaders` (plural) injeta

Para `mount_uploaders :photos, PhotoUploader` num `ApplicationRecord`. As entradas do `mount_base` repetem (pluralizadas naturalmente onde aplicável). As novas entradas exclusivas do bloco plural:

| Método | Retorno |
|---|---|
| `photos` | `Array[PhotoUploader]` |
| `photos=(new_files)` | atribui |
| `photos_urls(*args)` | `Array[String]` |
| `photos_cache` | `String?` (JSON-encoded names) |
| `photos_cache=(cache_name)` | atribui |
| `remote_photos_urls` | `Array[String]` |
| `remote_photos_urls=(urls)` | atribui |
| `remote_photos_request_headers=(headers)` | atribui (`Array` ou `Hash`) |
| `photos_identifiers` | `Array[String]` |

Os métodos do `mount_base` (`photos?`, `remove_photos`, `store_photos!`, etc.) usam o nome plural diretamente — mesmo template, com `<col>` = nome plural.

---

## RBS alvo

### Singular: `mount_uploader :avatar, AvatarUploader` no `User`

```rbs
# Generated by rbs_infer (carrierwave)

class ::User
  def avatar: () -> ::AvatarUploader
  def avatar=: (untyped) -> untyped
  def avatar?: () -> bool
  def avatar_url: (*::Symbol) -> ::String?
  def avatar_identifier: () -> ::String?

  def avatar_cache: () -> ::String?
  def avatar_cache=: (::String?) -> ::String?

  def remote_avatar_url: () -> ::String?
  def remote_avatar_url=: (::String?) -> ::String?
  def remote_avatar_request_header=: (untyped) -> untyped

  def remove_avatar: () -> (bool | ::String)
  def remove_avatar=: (bool | ::String) -> (bool | ::String)
  def remove_avatar?: () -> bool
  def remove_avatar!: () -> void
  def store_avatar!: () -> void
  def write_avatar_identifier: () -> void

  def avatar_integrity_error: () -> ::Exception?
  def avatar_processing_error: () -> ::Exception?
  def avatar_download_error: () -> ::Exception?
  def avatar_integrity_errors: () -> ::Array[::Exception]
  def avatar_processing_errors: () -> ::Array[::Exception]
  def avatar_download_errors: () -> ::Array[::Exception]

  def mark_remove_avatar_false: () -> void
  def reset_previous_changes_for_avatar: () -> void
  def remove_previously_stored_avatar: () -> void
  def remove_rolled_back_avatar: () -> void
end
```

### Plural: `mount_uploaders :photos, PhotoUploader` no `Post`

```rbs
# Generated by rbs_infer (carrierwave)

class ::Post
  def photos: () -> ::Array[::PhotoUploader]
  def photos=: (untyped) -> untyped
  def photos?: () -> bool
  def photos_urls: (*::Symbol) -> ::Array[::String]
  def photos_identifiers: () -> ::Array[::String]

  def photos_cache: () -> ::String?
  def photos_cache=: (::String?) -> ::String?

  def remote_photos_urls: () -> ::Array[::String]
  def remote_photos_urls=: (::Array[::String]) -> ::Array[::String]
  def remote_photos_request_headers=: (untyped) -> untyped

  def remove_photos: () -> (bool | ::String)
  def remove_photos=: (bool | ::String) -> (bool | ::String)
  def remove_photos?: () -> bool
  def remove_photos!: () -> void
  def store_photos!: () -> void
  def write_photos_identifier: () -> void

  def photos_integrity_errors: () -> ::Array[::Exception]
  def photos_processing_errors: () -> ::Array[::Exception]
  def photos_download_errors: () -> ::Array[::Exception]

  def mark_remove_photos_false: () -> void
  def reset_previous_changes_for_photos: () -> void
  def remove_previously_stored_photos: () -> void
  def remove_rolled_back_photos: () -> void
end
```

Notas sobre os tipos:

- **`avatar_url(*args)` retorno `String?`**: o método interno do uploader é `def url: (*Symbol) -> String` (per `gem_rbs_collection`), mas quando não há arquivo o uploader retorna `nil`. Manter `String?`.
- **`*args` como `*Symbol`**: a chamada é `avatar.url(*args)`, e `Uploader#url` é tipado como `(*Symbol) -> String` no collection. Compatível.
- **`Exception` para erros**: CarrierWave levanta `CarrierWave::IntegrityError`, `ProcessingError`, `DownloadError` — todos descendem de `StandardError`. Tipo amplo `Exception` mantém compatibilidade caso o usuário customize.
- **`remote_avatar_request_header=` aceita Hash[String, String]**: o tipo real é uma hash de cabeçalhos HTTP, mas o setter aceita `untyped` (CarrierWave repassa direto pro `Down`). Manter `untyped` por enquanto.

---

## Strip adicional no `sig/rbs_rails/`

O `rbs_rails` só emite `def <col>`, `def <col>=`, `def <col>?` para a coluna de tipo `string` (todos os outros — `<col>_changed?`, `<col>_was`, etc. — operam sobre o que está em DB, ou seja, `String?`, e devem ficar). O strip atual já está correto. **Não precisa expandir.**

Caso o usuário use `mount_uploader` numa coluna `text` ou `json` (cenário menos comum), o `rbs_rails` poderia gerar acessor com tipo diferente; o strip continua válido porque o regex casa qualquer assinatura.

---

## Plano de implementação

### 1. Refatorar `build_methods` no generator

Atual:

```ruby
def build_methods(call)
  attr = call[:name]
  uploader = "::#{call[:uploader]}"
  getter_type = call[:multiple] ? "Array[#{uploader}]" : uploader
  [
    # ~14 linhas hardcoded
  ]
end
```

Substituir por dois métodos especializados:

```ruby
def build_methods(call)
  call[:multiple] ? build_multiple_methods(call) : build_single_methods(call)
end

def build_single_methods(call)
  attr = call[:name]
  uploader = "::#{call[:uploader]}"
  [
    "  def #{attr}: () -> #{uploader}",
    "  def #{attr}=: (untyped) -> untyped",
    "  def #{attr}?: () -> bool",
    "  def #{attr}_url: (*::Symbol) -> ::String?",
    "  def #{attr}_identifier: () -> ::String?",
    "",
    "  def #{attr}_cache: () -> ::String?",
    "  def #{attr}_cache=: (::String?) -> ::String?",
    "",
    "  def remote_#{attr}_url: () -> ::String?",
    "  def remote_#{attr}_url=: (::String?) -> ::String?",
    "  def remote_#{attr}_request_header=: (untyped) -> untyped",
    "",
    *shared_methods(attr),
    "",
    "  def #{attr}_integrity_error: () -> ::Exception?",
    "  def #{attr}_processing_error: () -> ::Exception?",
    "  def #{attr}_download_error: () -> ::Exception?",
    *error_collection_methods(attr),
    "",
    *lifecycle_callback_methods(attr)
  ]
end

def build_multiple_methods(call)
  attr = call[:name]
  uploader = "::#{call[:uploader]}"
  [
    "  def #{attr}: () -> ::Array[#{uploader}]",
    "  def #{attr}=: (untyped) -> untyped",
    "  def #{attr}?: () -> bool",
    "  def #{attr}_urls: (*::Symbol) -> ::Array[::String]",
    "  def #{attr}_identifiers: () -> ::Array[::String]",
    "",
    "  def #{attr}_cache: () -> ::String?",
    "  def #{attr}_cache=: (::String?) -> ::String?",
    "",
    "  def remote_#{attr}_urls: () -> ::Array[::String]",
    "  def remote_#{attr}_urls=: (::Array[::String]) -> ::Array[::String]",
    "  def remote_#{attr}_request_headers=: (untyped) -> untyped",
    "",
    *shared_methods(attr),
    "",
    *error_collection_methods(attr),
    "",
    *lifecycle_callback_methods(attr)
  ]
end

def shared_methods(attr)
  [
    "  def remove_#{attr}: () -> (bool | ::String)",
    "  def remove_#{attr}=: (bool | ::String) -> (bool | ::String)",
    "  def remove_#{attr}?: () -> bool",
    "  def remove_#{attr}!: () -> void",
    "  def store_#{attr}!: () -> void",
    "  def write_#{attr}_identifier: () -> void"
  ]
end

def error_collection_methods(attr)
  [
    "  def #{attr}_integrity_errors: () -> ::Array[::Exception]",
    "  def #{attr}_processing_errors: () -> ::Array[::Exception]",
    "  def #{attr}_download_errors: () -> ::Array[::Exception]"
  ]
end

def lifecycle_callback_methods(attr)
  [
    "  def mark_remove_#{attr}_false: () -> void",
    "  def reset_previous_changes_for_#{attr}: () -> void",
    "  def remove_previously_stored_#{attr}: () -> void",
    "  def remove_rolled_back_#{attr}: () -> void"
  ]
end
```

### 2. Atualizar a expectation existente

Reescrever `spec/expectations/carrierwave/user.rbs` para refletir a nova lista de métodos.

### 3. Re-rodar o gerador no dummy

`make rbs_infer_carrierwave` e verificar que `spec/dummy/sig/rbs_carrierwave/app/models/user.rbs` casa com a nova expectation.

### 4. Snapshot de `mount_uploaders` (plural)

Decidir se vale forjar um caso plural no dummy só pra cobrir o gerador — ex.: criar um modelo fake `Gallery` com `mount_uploaders :photos, PhotoUploader` (não precisa rodar em runtime, só existir como source pra Prism parsear).

**Recomendação**: deixar como teste unitário direto sobre o `Generator` (passando um arquivo fake via `Tempfile`) em vez de mexer no schema do dummy. Mais barato e suficiente.

### 5. Regredir steep

Garantir que continua eliminando os 2 erros de `avatar.url` (e que nenhum erro novo apareceu por causa dos métodos extras).

### 6. (Opcional) Marcar como `untyped` os params dos métodos de error

`*_integrity_error[s]` retornam objetos de exceção customizados (`CarrierWave::IntegrityError`, etc.). Se o `gem_rbs_collection` tiver as classes específicas RBS-mapeadas, vale tipar mais fino depois. Por ora, `Exception` é seguro.

---

## Critério de "pronto"

1. Gerador emite todos os ~26 métodos do `mount_uploader` (singular) e ~24 do `mount_uploaders` (plural).
2. `store_previous_changes_for_<col>` removido do output (era inexistente).
3. Expectation `spec/expectations/carrierwave/user.rbs` atualizada.
4. Snapshot test verde.
5. Novo teste unitário cobrindo o caminho plural via `mount_uploaders`.
6. `make steep` continua em 15 erros (sem regressão).
7. `bundle exec rspec spec/integration/` 100% verde.

---

## Fora de escopo

- Refinar `untyped` nos setters (`avatar=`, `remote_avatar_request_header=`, etc.) para união precisa de tipos aceitos. CarrierWave aceita `IO`, `ActionDispatch::Http::UploadedFile`, `String`, `nil` — vale uma iteração futura.
- Mapear `CarrierWave::IntegrityError` / `ProcessingError` / `DownloadError` no lugar de `Exception`. Depende do fork do `gem_rbs_collection` tipar essas classes.
- Suporte a colunas serializadas (`serialize :avatar, JSON` + `mount_uploader`). Caso raro; tratar quando aparecer.
- Versões antigas (CarrierWave 2.x) — algumas assinaturas (`_url` plural vs singular, `request_header(s)=`) diferem. O gerador é validado contra 3.x.
