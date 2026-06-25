## Core layer namespaces (`ast` / `project` / `signatures` / `inference` / `markers`)

The core (`lib/rbs_infer/`) is split into layered namespaces (felixefelip/rbs_infer#26).
The dependency graph is **unidirectional** — a lower layer never reaches up to a
higher one:

```
ast         → (nothing)
project     → ast
signatures  → ast
inference   → ast + project + signatures
analyzer    → all of the above
markers     → consumed by analyzer; emit Steep postconditions
```

`analyzer.rb`, `railtie.rb`, `version.rb` stay at the top level.

| dir | namespace | role | example files |
|---|---|---|---|
| `ast/` | `RbsInfer::AST` | pure functions/visitors over the Prism syntax tree | `node_type_inferrer`, `def_collector`, `class_name_extractor`, `lexical_scope`, `target_discovery`, `constructor_type_inferrer` |
| `project/` | `RbsInfer::Project` | indices + caches over the file set | `parse_cache`, `file_index`, `source_index`, `dependency_sorter` |
| `signatures/` | `RbsInfer::Signatures` | read/write RBS, talk to Steep | `rbs_type_lookup`, `rbs_builder`, `method_type_resolver`, `steep_bridge` |
| `inference/` | `RbsInfer::Inference` | engines that decide types | `param_type_inferrer`, `return_type_resolver`, `type_merger`, `constant_type_resolver`, the class-body collectors |
| `markers/` | `RbsInfer::Markers` | synthesize Steep postcondition sidecars | `setter_marker_synthesizer`, `predicate_marker_synthesizer` |

> The namespace is `Signatures` (not `RBS`/`Steep`) on purpose — `RbsInfer::RBS`
> and `RbsInfer::Steep` would shadow the `rbs` and `steep` gems.

---

## The confusing pair: `ast` vs `inference`

### Mental model: **read** vs **conclude**

- **`ast` = read.** "What does this piece of syntax say, on its own?" A function
  of the syntax tree (plus pure parameters). No outside knowledge, no choices.
- **`inference` = conclude.** "Pulling together everything I can gather, what *is*
  the type?" It decides: arbitrates between sources, has a precedence order, falls
  back, consults Steep/RBS, looks across files and call-sites.

`ast` reads the words on the page; `inference` decides what the author meant by
weighing several clues.

### The three-question litmus test

| question | `ast` | `inference` |
|---|---|---|
| Does it need anything beyond this node? (Steep, RBS, other files, call-sites) | **no** | yes |
| Does it arbitrate between signals that can disagree? | no | **yes** |
| Is it a deterministic read of syntax (and free to return `nil` = "not my shape")? | **yes** | no — it commits to a final type |

### Worked example 1 — method parameters

Both look at an `initialize`'s parameters, but one reads and the other concludes.

**`AST::OptionalParamExtractor`** answers a *structural* question — "which params
are optional?" — and its constructor takes **nothing**, because the answer is in
the node itself (an `OptionalKeywordParameterNode` *is* optional by definition):

```ruby
class OptionalParamExtractor < Prism::Visitor
  def initialize          # ← no dependencies
    @optional_params = Set.new
  end
  # visit_def_node: collect names of optional keyword/positional params
end
```

**`Inference::ParamTypeInferrer`** answers a *conclusion* question — "what is each
param's type?" — which is **not** in the node. Its constructor signature gives the
game away:

```ruby
def initialize(target_file:, target_class:, source_files:,
               source_index:, method_type_resolver:, type_merger:,
               steep_bridge:, parse_cache:, file_index:, caller_file_cache:)
```

It needs the whole project: it visits **call-sites in other files**
(`User.new(name: "Jo")` → `name` is `String`), weighs forwarding wrappers, and
consults RBS/Steep.

They collaborate without inverting the hierarchy: `ParamTypeInferrer` *uses*
`RbsInfer::AST::DefCollector` to pull the structural list of param names, then
infers types on top. `inference → ast`, never the reverse.

### Worked example 2 — a class split exactly on the line

`ConstantTypeResolver` was one class cut into two, one half on each side:

- **`AST::ConstructorTypeInferrer`** reports only the syntactic shape:
  `Foo.new → "Foo"`, `new`/`self.new → target class`, `{...}.map { new } → "Array[<target>]"`,
  and `nil` for anything else ("not a shape I describe"). It consults nothing and
  has no fallback.
- **`Inference::ConstantTypeResolver`** is the one that *decides*, via a precedence
  policy that always commits to a final type:

  ```ruby
  @constructor_inferrer.infer(node) ||   # 1. the AST shape read above
    usable_steep_type(steep_type) ||     # 2. Steep (ran the checker project-wide)
    infer_node_type(node, ...) ||        # 3. leaf inference (literals)
    "untyped"                            # 4. give up, but ALWAYS return a type
  ```

### The two cases that look like exceptions (they aren't)

1. **Body collectors (`ClassMemberCollector`, `InitializeBodyAnalyzer`, …) are in
   `inference`, even though they're `Prism::Visitor`s.** The line is not
   "visitor or not". Pure AST visitors (`DefCollector`, `ClassNameExtractor`,
   `TargetDiscovery`) only gather *structural facts* — "here are the def nodes",
   "this class is named `Foo`", "these are the declaration targets". The body
   collectors apply *type judgment* while they walk (they `include NodeTypeInferrer`,
   decide "this assignment means the ivar has type X"). Walking the tree is
   incidental; emitting a type judgment is what makes them `inference`.

2. **`NodeTypeInferrer` and `ConstructorTypeInferrer` have "Inferrer" in the name
   but live in `ast`.** Their "inference" is *local and mechanical*:
   `"text" → String`, `:a → Symbol`, `Foo.new → Foo`. The syntax determines the
   answer — no judgment, no external source. That is different from the
   project-level type-deciding the `inference` engines do. Trust the litmus test,
   not the name.

---

## `module` vs `class` *within* a layer

Independently of which layer a file is in, pick the shape by **state**, not purity:

| shape | when | examples |
|---|---|---|
| `module` (+ `module_function`, or as a mixin) | stateless namespace of functions, or a mixin shared across classes | `AST::NodeTypeInferrer` (mixed into resolvers), `AST::LexicalScope` |
| `class` | holds something across calls — either accumulated state, or a fixed config/context parameter | `AST::DefCollector`/`TargetDiscovery` (accumulate while visiting); `AST::ConstructorTypeInferrer` (holds `target_class` as an ivar) |

A "stateless but parameterized" object (e.g. `ConstructorTypeInferrer`, which holds
only an immutable `target_class`) is still a **class** — a function/policy object.
It gives natural privacy (plain `private` helpers) and matches the other `ast/`
analyzers that take `target_class` in their initializer. Reserve `module_function`
for things that are *also* `include`d somewhere; otherwise its module-level methods
are public, which is a footgun if you wanted a single public entry point.

---

## Deciding where a new file goes

1. Does it only need the Prism node (+ pure params), with no Steep/RBS/cross-file
   lookups and no arbitration? → **`ast/`**
2. Is it an index or cache over the file set? → **`project/`**
3. Does it read or write RBS, or drive Steep? → **`signatures/`**
4. Does it combine the above to *decide* a type (precedence, fallbacks, call-site
   or cross-file evidence)? → **`inference/`**
5. Does it synthesize a Steep postcondition sidecar? → **`markers/`**

When in doubt between `ast` and `inference`, run the three-question litmus test —
"needs only the node?", "arbitrates?", "may return nil?".

### A note on threaded dependencies

Layers reach down by having the dependency **threaded in** (passed to the
constructor), not by reaching for a global. Follow
[required-threaded-deps.md](required-threaded-deps.md): make those kwargs
**required**, so a caller that forgets to wire one fails loudly instead of
silently degrading.
