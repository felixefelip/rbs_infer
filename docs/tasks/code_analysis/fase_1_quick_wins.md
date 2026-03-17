# Fase 1 — Quick wins independentes

Mudanças isoladas que não afetam interfaces. Zero risco de quebrar algo.

---

## 1.1 `rescue next` → `rescue Errno::ENOENT, Errno::EACCES`

**Problema:** `rescue next` captura qualquer exceção, incluindo bugs no código.

**Arquivos:**
- `lib/rbs_infer/method_type_resolver.rb`
- `lib/rbs_infer/param_type_inferrer.rb`

**Antes:**
```ruby
source = File.read(file) rescue next
```

**Depois:**
```ruby
begin
  source = File.read(file)
rescue Errno::ENOENT, Errno::EACCES
  next
end
```

---

## 1.2 `ITERATOR_METHODS` — mover para `RbsInfer`

**Problema:** Constante definida em `Analyzer` e referenciada via `Analyzer::ITERATOR_METHODS` em `ParamTypeInferrer`. Acoplamento frágil.

**Arquivos:**
- `lib/rbs_infer.rb` (definir a constante)
- `lib/rbs_infer/analyzer.rb` (remover definição, referenciar `RbsInfer::ITERATOR_METHODS`)
- `lib/rbs_infer/param_type_inferrer.rb` (referenciar `RbsInfer::ITERATOR_METHODS`)

**Antes:**
```ruby
# analyzer.rb
ITERATOR_METHODS = %i[each map flat_map select reject filter find detect collect each_with_object].to_set

# param_type_inferrer.rb
ITERATOR_METHODS = Analyzer::ITERATOR_METHODS
```

**Depois:**
```ruby
# rbs_infer.rb
module RbsInfer
  ITERATOR_METHODS = %i[each map flat_map select reject filter find detect collect each_with_object].to_set
end

# analyzer.rb / param_type_inferrer.rb
RbsInfer::ITERATOR_METHODS
```

---

## 1.3 Guards redundantes antes de `extract_constant_path`

**Problema:** `extract_constant_path` já retorna `nil` para nós que não são `ConstantReadNode` ou `ConstantPathNode`. Os checks `is_a?` são desnecessários.

**Arquivos:**
- `lib/rbs_infer/return_type_resolver.rb`
- `lib/rbs_infer/method_type_resolver.rb`
- `lib/rbs_infer/param_type_inferrer.rb`
- `lib/rbs_infer/new_call_collector.rb`

**Antes:**
```ruby
if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
  class_name = Analyzer.extract_constant_path(node.receiver)
  if class_name
    # ...
  end
end
```

**Depois:**
```ruby
class_name = Analyzer.extract_constant_path(node.receiver)
if class_name
  # ...
end
```

---

## 1.4 `chomp("?")` → `delete_suffix("?")`

**Problema:** `chomp("?")` e `delete_suffix("?")` têm o mesmo efeito para este caso, mas `delete_suffix` é mais explícito e idiomático para a intenção de "remover sufixo de tipo opcional".

**Arquivos:**
- `lib/rbs_infer/return_type_resolver.rb`
- `lib/rbs_infer/new_call_collector.rb`

**Antes:**
```ruby
base_type = safe_nav ? receiver_type.chomp("?") : receiver_type
```

**Depois:**
```ruby
base_type = safe_nav ? receiver_type.delete_suffix("?") : receiver_type
```

---

## 1.5 CamelCase → snake_case — extrair método utilitário

**Problema:** O pattern `class_name.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase` aparece em 5+ lugares. Não suporta acrônimos (`HTMLParser` → `htmlparser` em vez de `html_parser`).

**Arquivos:**
- `lib/rbs_infer.rb` (definir o método)
- `lib/rbs_infer/analyzer.rb`
- `lib/rbs_infer/method_type_resolver.rb`
- `lib/rbs_infer/rbs_type_lookup.rb`
- `lib/rbs_infer/param_type_inferrer.rb`

**Antes:**
```ruby
class_path = class_name.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
```

**Depois:**
```ruby
# rbs_infer.rb
module RbsInfer
  def self.class_name_to_path(class_name)
    class_name.sub(/\A::/, "")
              .gsub("::", "/")
              .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z])([A-Z])/, '\1_\2')
              .downcase
  end
end

# nos arquivos que usam:
class_path = RbsInfer.class_name_to_path(class_name)
```

---

## Checklist

- [ ] 1.1 — `rescue next` explícito
- [ ] 1.2 — `ITERATOR_METHODS` no módulo `RbsInfer`
- [ ] 1.3 — Remover guards redundantes
- [ ] 1.4 — `chomp("?")` → `delete_suffix("?")`
- [ ] 1.5 — Extrair `class_name_to_path`
- [ ] Rodar `bundle exec rspec` — 0 failures
- [ ] Commit
