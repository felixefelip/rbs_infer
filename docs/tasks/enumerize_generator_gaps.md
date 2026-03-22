# Enumerize Generator — Análise de Gaps

Análise comparativa entre a API completa da gem [enumerize](https://github.com/brainspec/enumerize) e o que o gerador RBS em `lib/rbs_infer/enumerize_generator.rb` implementa atualmente.

## Funcionalidades já implementadas ✅

| Feature | Opção | Status |
|---------|-------|--------|
| Valores básicos (array) | `in: [:a, :b]` | ✅ |
| Valores customizados (hash) | `in: { a: 1, b: 2 }` | ✅ |
| Default | `default: :a` | ✅ (getter non-nilable) |
| Default com lambda | `default: -> { ... }` | ✅ (detecta a presença da key) |
| Predicados no value object | `status.draft?` | ✅ (gerado na value class) |
| Predicados na instância | `predicates: true` | ✅ |
| Predicados com prefixo | `predicates: { prefix: true }` | ✅ |
| Predicados only/except | `predicates: { only: [...] }` | ✅ |
| Scopes shallow | `scope: :shallow` | ✅ (`self.draft`, `self.not_draft`) |
| Scopes deep | `scope: true` | ✅ (`self.with_status`, `self.without_status`) |
| Multiple | `multiple: true` | ✅ (retorna `Enumerize::Set`) |
| Método `_text` | `status_text` | ✅ |
| Método `_value` | `status_value` | ✅ |
| Setter | `status=` | ✅ |

## Funcionalidades faltantes ou com bugs 🔴

### 1. Custom scope names (BUG)

**Prioridade: Alta**

A gem permite nomes de scope customizados:

```ruby
enumerize :status, in: [:a, :b], scope: :having_status
```

Isso gera o scope `User.having_status(:a)` (equivalente a `with_status`).

O código atual em `extract_scope_option` retorna o símbolo correto (`:having_status`), mas `build_scope_methods` só trata `:shallow` e `:deep`. Qualquer outro símbolo cai no `else` implícito e **nenhum scope é gerado**.

**Correção**: Tratar scope com nome customizado como deep scope usando o nome fornecido:

```ruby
# Esperado:
def self.having_status: (*String | Symbol) -> Post::ActiveRecord_Relation
```

### 2. Métodos de classe do atributo enumerized

**Prioridade: Média**

A gem adiciona accessors no nível da classe que retornam um `Enumerize::Attribute`:

```ruby
User.status          # => Enumerize::Attribute
User.status.values   # => ['student', 'employed', 'retired']
User.status.options  # => [['Student', 'student'], ...]
User.status.find_value(:student) # => Enumerize::Value
```

O gerador não emite nenhum tipo para esses métodos de classe. Isso é usado frequentemente em forms, selects e lógica condicional.

**RBS esperado**:

```rbs
class ::User
  def self.status: () -> Enumerize::Attribute
end
```

### 3. `enumerized_attributes` class method

**Prioridade: Baixa**

```ruby
User.enumerized_attributes          # => hash-like de atributos
User.enumerized_attributes[:status] # => Enumerize::Attribute
```

Usado raramente em application code, mais em metaprogramação.

**RBS esperado**:

```rbs
class ::User
  def self.enumerized_attributes: () -> Enumerize::AttributeMap
end
```

### 4. Tipo de retorno de `_value` para valores customizados (hash)

**Prioridade: Média**

Quando se usa `in: { user: 1, admin: 2 }`:

```ruby
user.role        # => 'user' (string)
user.role_value  # => 1 (integer)
```

O gerador sempre emite `def role_value: () -> String?`, mas quando a hash tem valores Integer, o retorno deveria ser `Integer?`.

**RBS esperado**:

```rbs
# in: { user: 1, admin: 2 }
def role_value: () -> Integer?

# in: [:draft, :published]  (array, sem valores custom)
def role_value: () -> String?
```

**Implementação**: Ao parsear `in:` com `HashNode`, extrair e armazenar o tipo dos valores (Integer, String, etc.) além dos nomes.

### 5. Enumerize em módulos (extendable modules)

**Prioridade: Baixa**

A gem permite definir enumerize num módulo compartilhado:

```ruby
module RoleEnumerations
  extend Enumerize
  enumerize :roles, in: %w[user admin]
end

class Buyer
  include RoleEnumerations
end
```

O gerador atualmente só escaneia `app/models/**/*.rb` e só extrai de `ClassNode`. Não detecta enumerize em módulos (concerns) nem propaga para classes que incluem esses módulos.

**Escopo**: Suportar `ModuleNode` na extração e gerar RBS correspondente. A propagação para classes incluídas é mais complexa e pode ser adiada.

### 6. Nested classes / múltiplas classes por arquivo

**Prioridade: Baixa**

`extract_class_info` retorna apenas a primeira `ClassNode` encontrada. Se um arquivo tem múltiplas classes ou classes aninhadas, apenas a primeira é processada.

**Exemplo problemático**:

```ruby
class Post < ApplicationRecord
  class Draft < Post
    extend Enumerize
    enumerize :review_status, in: [:pending, :approved]
  end
end
```

### 7. Método `texts` em `Enumerize::Set` para `multiple: true`

**Prioridade: Baixa**

```ruby
user.interests.texts  # => ['Music', 'Sports']
```

O gerador já retorna `Enumerize::Set` para atributos `multiple: true`. O suporte a `.texts` depende da definição de `Enumerize::Set` em `gem_rbs_collection`, não do nosso gerador. Apenas documentar a dependência.

### 8. Método `.text` no value object

**Prioridade: Baixa**

```ruby
user.status.text  # => "Student"
```

O gerador já gera a value class (`Post::EnumerizeStatusValue < Enumerize::Value`). O método `.text` vem de `Enumerize::Value` na base class. Se `gem_rbs_collection` define `text` em `Enumerize::Value`, já funciona. Verificar se está definido.

## Melhorias de qualidade (não são features faltantes)

### 9. Suporte a `%w[]` na extração de valores

**Prioridade: Média**

A gem documenta uso com `%w[]`:

```ruby
enumerize :status, in: %w[student employed retired]
```

O gerador usa `extract_symbol_array` que trata `ArrayNode` com `SymbolNode` elements. Strings de `%w[]` são `StringNode` no Prism, não `SymbolNode`, então **esses valores não seriam extraídos**.

**Correção**: Adicionar tratamento de `StringNode` em `extract_symbol_value`.

### 10. Relação type hardcoded como `ActiveRecord_Relation`

**Prioridade: Baixa**

O gerador hardcoda `"#{class_name}::ActiveRecord_Relation"` para scopes. Se a classe não é ActiveRecord (ex: Mongoid), isso estaria errado. Pode ser aceito como limitação documentada dado que o foco é Rails/AR.

## Priorização sugerida

| # | Feature | Prioridade | Complexidade | Impacto |
|---|---------|-----------|-------------|---------|
| 1 | Fix custom scope names (bug) | Alta | Baixa | Corrige scopes quebrados |
| 9 | Suporte a `%w[]` | Média | Baixa | Evita missing values silencioso |
| 4 | Tipo de `_value` para hash values | Média | Média | Tipo mais preciso |
| 2 | Class-level attribute accessors | Média | Média | Muito usado em forms |
| 5 | Enumerize em módulos | Baixa | Alta | Caso de uso avançado |
| 6 | Nested/múltiplas classes | Baixa | Média | Edge case raro |
| 3 | `enumerized_attributes` | Baixa | Baixa | Pouco usado |
| 7 | Documentar `Enumerize::Set#texts` | Baixa | Nenhuma | Apenas doc |
| 8 | Verificar `Enumerize::Value#text` | Baixa | Nenhuma | Apenas verificação |
| 10 | Documentar limitação AR-only | Baixa | Nenhuma | Apenas doc |
