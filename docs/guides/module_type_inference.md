# Module and Concern Type Inference

## The problem

Steep cannot resolve method calls inside a Ruby module without knowing what class will include
it. Given:

```ruby
module Post::Notifiable
  def notification_payload
    { post_id: id, title: title }  # ← Steep doesn't know what `id` or `title` are
  end
end
```

Without context, `id` and `title` are `untyped`. Steep needs a hint:

```ruby
# @type instance: Post & Post::Notifiable
```

With that annotation, Steep knows `self` has both `Post` and `Post::Notifiable` as its type,
and can resolve `id → Integer` and `title → String` from the `Post` RBS definition.

For concerns that also have `class_methods` or `included do` blocks, Steep also needs to know
the singleton context:

```ruby
# @type self: singleton(Post) & singleton(Post::Notifiable)
```

---

## The solution: parse-time annotation injection

Writing these annotations by hand in every module file is fragile and repetitive. Instead, we
inject them **in memory at parse time** inside the Steep fork, following the same pattern as
`STEEP_ERB_CONVENTION` (which does the same for ERB views).

No files on disk are ever modified. The annotation lives only in Steep's in-memory
representation of the source.

---

## How the two projects fit together

```
┌─────────────────────────────────────────────────────────────────┐
│  rbs_infer (this gem)                                           │
│                                                                 │
│  Analyzer                                                       │
│  ├── reads source with ModuleSelfTypeResolver.annotate()        │
│  │   (same logic as Steep fork, applied before Prism.parse)     │
│  └── uses SteepBridge to build return types via Steep's         │
│      type construction pipeline                                 │
│                                                                 │
│  SteepBridge                                                    │
│  └── calls Steep::Source.parse(source_code, path:, factory:)   │
│      which triggers the fork's injection automatically when     │
│      STEEP_MODULE_CONVENTION is set                             │
└──────────────────────────────┬──────────────────────────────────┘
                               │ calls
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  Steep fork (github.com/felixefelip/steep)                      │
│                                                                 │
│  Source.parse(source_code, path:, factory:)          [source.rb]│
│  └── if STEEP_MODULE_CONVENTION && path ends with .rb:          │
│        source_code = ModuleSelfTypeResolver.annotate(path, src) │
│                                                                 │
│  ModuleSelfTypeResolver.annotate(path, source_code)             │
│  [lib/steep/source/module_self_type_resolver.rb]                │
│  ├── derives module name from file path (namespace convention)  │
│  ├── determines if it is a concern or plain module              │
│  └── inserts @type comments into the in-memory source           │
└─────────────────────────────────────────────────────────────────┘
```

### Why rbs_infer also calls the resolver directly

`SteepBridge` passes annotated source through `Steep::Source.parse`, so Steep itself always
sees the annotations. But `Analyzer` also parses the source with **Prism** (not Steep) to
extract instance type annotations (`@type instance:`) and decide which including class to use
when generating the RBS output. Because Prism reads the file from disk directly, without the
Steep fork's parse-time hook, `Analyzer` must apply the same `ModuleSelfTypeResolver.annotate`
call before passing the source to `Prism.parse`:

```ruby
# analyzer.rb
source = File.read(@target_file)
source = Steep::Source::ModuleSelfTypeResolver.annotate(@target_file, source)
result = Prism.parse(source)
```

This keeps both tools in sync without duplicating the annotation logic.

---

## Enabling the feature

Set the environment variable before running Steep:

```ruby
# Steepfile
ENV["STEEP_MODULE_CONVENTION"] = "1"
```

No other configuration is needed. `rbs_infer` reads it automatically and the Steep fork
respects it at parse time.

---

## Annotation rules

| File | Injected annotations |
|---|---|
| Concern (`extend ActiveSupport::Concern`) | `# @type self: singleton(Post) & singleton(Post::Notifiable)` + `# @type instance: Post & Post::Notifiable` |
| Plain module | `# @type instance: Post & Post::Taggable` only |

**Why no `@type self:` for plain modules?**
In a concern, `included do` and `class_methods do` blocks run in the singleton context of the
including class. Steep needs `@type self:` to resolve class-level calls inside them. In a
plain module, `self` inside instance methods is always the including instance — `@type instance:`
covers it completely.

---

## How the module name is derived

The module name is derived from the file path using the Rails autoload convention:

```
app/models/post/notifiable.rb   → Post::Notifiable  → including: Post
app/models/user/recoverable.rb  → User::Recoverable → including: User
app/models/post/taggable.rb     → Post::Taggable    → including: Post
```

`app/models/concerns/` is an autoload root in Rails (same level as `app/models/`), so the
`concerns/` prefix is stripped before camelizing:

```
app/models/concerns/test/filtrable.rb → test/filtrable → Test::Filtrable → including: Test
```

The algorithm (`ModuleSelfTypeResolver.annotate`):

```
1. Extract the path relative to app/models/
2. Strip concerns/ prefix if present
3. Split by / and camelize each segment
4. Derive including_class from all but the last segment
5. Skip if < 2 segments (no namespace → Strategy B not yet implemented)
6. Skip if already annotated (idempotent)
7. Inject annotations at the right insertion point
```

---

## Where the code lives

| Location | Description |
|---|---|
| [`lib/steep/source/module_self_type_resolver.rb`](https://github.com/felixefelip/steep/blob/main/lib/steep/source/module_self_type_resolver.rb) | Core injection logic (Steep fork) |
| [`lib/steep/source.rb:51-53`](https://github.com/felixefelip/steep/blob/main/lib/steep/source.rb) | Hook in `Source.parse` that calls the resolver (Steep fork) |
| [`lib/rbs_infer/analyzer.rb`](../../lib/rbs_infer/analyzer.rb) | Applies the same resolver before `Prism.parse` |
| [`test/source/module_self_type_resolver_test.rb`](https://github.com/felixefelip/steep/blob/main/test/source/module_self_type_resolver_test.rb) | Unit tests for the resolver (Steep fork) |

---

## Known limitations

| Scenario | Current behaviour |
|---|---|
| Module without namespace (`module Taggable`) | Skipped — including class cannot be derived from path alone (Strategy B not implemented) |
| Multiple classes include the same module | Only the namespace-derived class is used; Strategy B would scan all files for `include ModuleName` |
| `extend ActiveSupport::Concern` inside a nested block | Detected by simple string match — always treated as a concern even if nested |
