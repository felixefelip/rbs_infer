# Plano: upload de `User#avatar` com CarrierWave

Implementar upload de avatar do `User` no `spec/dummy` usando a gem CarrierWave com file storage local e sem processamento de imagem.

## Decisões já tomadas
- **Modelo alvo:** `User#avatar` (campo único).
- **Processamento:** nenhum (sem MiniMagick, sem versions).
- **Storage:** file storage local em `public/uploads`.

## Contexto relevante
- `UsersController` só tem `index`/`show` — não há `new/create/edit/update` nem views. Para exercitar o upload via formulário, precisaremos adicionar ao menos `edit`/`update` (ou testar via console).
- Tabela `users` (`spec/dummy/db/schema.rb:14`) não tem coluna de arquivo; precisa de migração.
- Repo é o `rbs_infer`, então depois do código precisamos rodar a geração de sigs e checar com Steep.

## Passos

1. **Adicionar a gem**
   - `spec/dummy/Gemfile`: `gem "carrierwave", "~> 3.0"`
   - `cd spec/dummy && bundle install`

2. **Gerar o uploader**
   - `bin/rails g uploader Avatar` → cria `spec/dummy/app/uploaders/avatar_uploader.rb`
   - Manter `storage :file` (default), `store_dir` baseado em model/mounted_as/id, e uma whitelist em `extension_allowlist` (`%w[jpg jpeg gif png webp]`).

3. **Migração para coluna `avatar`**
   - `bin/rails g migration AddAvatarToUsers avatar:string`
   - `bin/rails db:migrate` (a coluna guarda o nome do arquivo, não o binário).

4. **Montar o uploader no model**
   - Em `app/models/user.rb`: `mount_uploader :avatar, AvatarUploader`
   - Opcional: validação de tamanho via gem auxiliar — pulamos por enquanto.

5. **Habilitar edição no controller**
   - Adicionar `edit` e `update` em `UsersController` com `user_params` permitindo `:avatar` e `:avatar_cache` (CarrierWave usa o cache pra reexibir o arquivo quando o form falha validação).
   - Atualizar `config/routes.rb` para `resources :users, only: [:index, :show, :edit, :update]` (confirmar estado atual ao implementar).

6. **Views**
   - `app/views/users/edit.html.erb`: `form_with model: @user` com `f.file_field :avatar` + `f.hidden_field :avatar_cache`. Se já houver avatar, mostrar preview e checkbox `:remove_avatar`.
   - `app/views/users/show.html.erb`: `<%= image_tag @user.avatar.url if @user.avatar.present? %>`.

7. **Storage / .gitignore**
   - Verificar `spec/dummy/public/uploads/` (CarrierWave cria) e adicionar ao `.gitignore` do dummy para não commitar artefatos de teste.
   - `tmp/` já está ignorado, então o cache não precisa de configuração extra.

8. **Validar manualmente**
   - `bin/rails s`, acessar `/users/:id/edit`, subir um PNG/JPEG, verificar que `User#avatar.url` retorna `/uploads/user/avatar/:id/file.png`.

9. **RBS (específico deste repo)**
   - Rodar o pipeline do `rbs_infer` no dummy para gerar sigs do uploader (`AvatarUploader < CarrierWave::Uploader::Base`) e dos novos métodos que `mount_uploader` adiciona ao `User` (`avatar`, `avatar=`, `avatar?`, `remove_avatar`, `avatar_cache`).
   - Provavelmente vão aparecer constantes/métodos faltando — esse é justamente o tipo de cenário que o `rbs_infer` deve cobrir; vale anotar gaps em `docs/tasks/type_inference_gaps.md` se for o caso.
   - Rodar `steep check` no dummy para confirmar que não regrediu.

## Pontos de atenção
- CarrierWave 3 exige `image_processing`/`mini_magick` só se usarmos `process`/`version` — como optamos por não processar, fica fora.
- Não confundir com ActiveStorage (Rails 8 já vem com ele); este plano usa **apenas** CarrierWave conforme pedido.
- Se quiser pular o trabalho de views/controller, dá pra encurtar para passos 1–4 + 9 e testar via `rails console` (`u.avatar = File.open(...); u.save!`).
