# Estratégias do Steep aplicáveis ao rbs_infer

Análise comparativa entre o Steep (type checker completo) e o rbs_infer (gerador de RBS por inferência estática), com foco em estratégias concretas de implementação.

---

## 1. Tipos como objetos em vez de strings (impacto mais alto)

**Steep**: Cada tipo é um objeto imutável com métodos polimórficos (`subst`, `free_variables`, `to_s`, `==`, `hash`, `each_child`, `map_type`). Tipos primitivos (`Any`, `Nil`, `Boolean`) usam **Singleton** — uma única instância por tipo.

**rbs_infer hoje**: Tipos são strings (`"String"`, `"Array[untyped]"`, `"(String | Integer)"`). Para extrair o return type ou attr type de um `Member`, cada consumidor faz regex: `m.signature =~ /->\s*(.+)$/`.

**Proposta concreta** — criar um módulo `RbsInfer::Types`:

```ruby
module RbsInfer::Types
  class Simple  # "String", "Integer", "Post"
    attr_reader :name
    def to_s = name
  end

  class Union  # "(String | Integer)"
    attr_reader :types
    def self.build(types) = # flatten nested unions, dedup, simplify
    def to_s = "(#{types.map(&:to_s).join(" | ")})"
  end

  class Generic  # "Array[String]", "Hash[Symbol, Integer]"
    attr_reader :name, :args
    def to_s = "#{name}[#{args.map(&:to_s).join(", ")}]"
  end

  class Untyped  # Singleton
    extend SharedInstance
    def to_s = "untyped"
  end

  class Void
    extend SharedInstance
    def to_s = "void"
  end
end
```

**Benefícios**: Elimina ~14 regex matches espalhados em 8 arquivos. `Union.build` pode fazer flatten/dedup automaticamente (como o Steep faz em `ast/types/union.rb`). `Member` passaria a ter `return_type: Types::t` em vez de uma string `signature` a ser parseada por regex.

---

## 2. Structural equality via mixin `Equatable`

**Steep**: O módulo `Equatable` define `==`, `eql?`, `hash` baseado em **todas** as instance variables. Todos os tipos incluem este mixin, permitindo uso direto como chaves de Hash/Set.

**Proposta** — Um mixin simples que o rbs_infer pode usar nos tipos:

```ruby
module RbsInfer::Equatable
  def ==(other)
    other.class == self.class &&
      instance_variables.all? { |name|
        other.instance_variable_get(name) == instance_variable_get(name)
      }
  end
  alias eql? ==
  def hash
    instance_variables.inject(self.class.hash) { |h, name|
      h ^ instance_variable_get(name).hash
    }
  end
end
```

---

## 3. `Member` com campos estruturados

**Steep**: `MethodType` possui campos tipados: `type_params`, `type` (Function), `block`. Nunca precisa de regex para extrair partes.

**rbs_infer hoje**: `Member` é um Struct com `signature: "initialize: (Post post, ?notifier: Notifier) -> void"` — uma string bruta que precisa de regex.

**Proposta** — Expandir `Member` com campos:

```ruby
Member = Struct.new(
  :kind,           # :method, :attr_accessor, :attr_reader, :attr_writer, :include
  :name,           # "initialize"
  :params,         # [{name: "post", type: Types::Simple("Post")}, ...]
  :return_type,    # Types::Void.instance
  :visibility,     # :public, :private, :protected
  keyword_init: true
) do
  def signature  # backward-compat: gera a string RBS
    # ...
  end
end
```

---

## 4. Cache global de arquivos parseados

**Steep**: A `Factory` cacheia `@type_cache[rbs_type] = steep_type` — nunca converte o mesmo tipo duas vezes. O `SourceIndex` opera sobre nós AST já parseados.

**rbs_infer hoje**: `File.read` + `Prism.parse` são chamados **repetidamente** para os mesmos arquivos em `MethodTypeResolver`, `CallerFileAnalyzer`, `ParamTypeInferrer`, etc.

**Proposta** — `ParsedFileCache` centralizado:

```ruby
class RbsInfer::ParsedFileCache
  def initialize
    @cache = {}
  end

  def get(file_path)
    @cache[file_path] ||= begin
      source = File.read(file_path)
      result = Prism.parse(source)
      RbsInfer::ParsedFile.new(
        result: result, source: source,
        comments: result.comments, lines: source.lines
      )
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
```

Passar para `Analyzer`, que propaga para `MethodTypeResolver`, `CallerFileAnalyzer`, etc. Evita re-parsing O(n²) em projetos Rails grandes.

---

## 5. Lazy evaluation nas Shapes

**Steep**: O `Shape::Entry` guarda um bloco `@generator` e só calcula os overloads quando `force` é chamado. Isso permite construir shapes baratas e só materializar as que são realmente consultadas.

**Proposta** — Aplicar no `MethodTypeResolver#resolve_all`:

```ruby
def resolve_all(class_name)
  @cache[class_name] ||= LazyClassTypes.new { build_class_types(class_name) }
end
```

Onde `LazyClassTypes` só faz o resolve quando um método específico é consultado. No rbs_infer, `resolve_all` resolve **todos** os métodos de uma classe mesmo quando apenas um é necessário.

---

## 6. Context threading imutável

**Steep**: A cada nó AST processado, `synthesize` retorna um `Pair(type, constr)` onde `constr` é um **novo** `TypeConstruction` com contexto atualizado. O contexto anterior nunca é mutado, permitindo branching em `if/else`.

**rbs_infer hoje**: Usa hashes mutáveis (`@local_var_types`, `known_return_types`) que são copiados via `.dup` antes de entrar em escopos filhos — frágil e propenso a bugs quando o `.dup` é esquecido.

**Proposta gradual**: Não é necessário reescrever tudo, mas os visitors que mudam `@local_var_types` (como `NewCallCollector#visit_def_node`) deveriam usar uma abordagem mais explícita:

```ruby
def visit_def_node(node)
  with_scope(@local_var_types) do  # salva e restaura automaticamente
    collect_local_assignments(node)
    super
  end
end

def with_scope(env)
  saved = env.dup
  yield
ensure
  @local_var_types = saved
end
```

---

## 7. SourceIndex mais rico

**Steep**: O `SourceIndex` rastreia **definições** e **referências** separadamente, tanto para constantes quanto para métodos. Isso permite "Go to Definition" e análises bidirecionais.

**rbs_infer hoje**: O `SourceIndex` só faz regex de tokens CamelCase → lista de arquivos. Não distingue definição de referência.

**Proposta incremental**: Ao construir o index, detectar padrões como `class Foo` (definição) vs. `Foo.new` (referência). Isso permitiria:
- `find_definition("Post")` → arquivo que define a classe
- `find_references("Post")` → arquivos que usam a classe
- Evitar falsos positivos do match por substring

---

## Resumo — Prioridade × Esforço

| # | Estratégia | Impacto | Esforço |
|---|---|---|---|
| **4** | Cache global de parsing | Alto (performance) | Baixo |
| **1+3** | Tipos como objetos + Member estruturado | Alto (elimina regex, manutenibilidade) | Médio |
| **2** | Mixin Equatable | Médio (habilita caching por tipo) | Baixo |
| **6** | Scope management com `with_scope` | Médio (corretude) | Baixo |
| **7** | SourceIndex mais rico | Médio (precisão) | Médio |
| **5** | Lazy resolution | Médio (performance) | Médio |

As estratégias **4** (cache de parsing) e **6** (scope management) podem ser implementadas rapidamente com impacto imediato. As estratégias **1+3** (tipos como objetos + Member estruturado) são o investimento de mais longo prazo com o maior retorno arquitetural — eliminariam a duplicação de inferência de tipos AST e as ~14 regex parses espalhadas pelo código.
