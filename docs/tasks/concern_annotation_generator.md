# Module `@type` Annotation — `STEEP_MODULE_CONVENTION`

## Context

Steep requires `# @type self:` and `# @type instance:` comments inside modules to understand
the instance context when those modules are included in a class. Without them, Steep cannot
resolve method calls on `self` or instance variables inside the module body.

These annotations are **not written to disk**. Following the same pattern as
`STEEP_ERB_CONVENTION`, the Steep fork injects them **in memory at parse time**: the
`ModuleSelfTypeResolver.annotate(path, source_code)` call returns a modified copy of the
source that is parsed instead of the original. Files on disk are never touched.

---

## Where the implementation lives

This is entirely inside the **Steep fork**, not in `rbs_infer`:

| File | Role |
|---|---|
| `lib/steep/source.rb:51-53` | Calls `ModuleSelfTypeResolver.annotate` when `STEEP_MODULE_CONVENTION` is set |
| `lib/steep/source/module_self_type_resolver.rb` | Implementation (in progress) |

The env var is already enabled in the dummy app's `Steepfile`:

```ruby
ENV["STEEP_MODULE_CONVENTION"] = "1"
```

---

## How it works (parse-time injection)

```ruby
# source.rb — analogous to the ERB convention
if ENV["STEEP_MODULE_CONVENTION"] && path.to_s.end_with?(".rb")
  source_code = ModuleSelfTypeResolver.annotate(path, source_code)
end
```

`ModuleSelfTypeResolver.annotate` receives the path and the original source, returns an
annotated copy. The rest of the Steep pipeline sees the annotations as if they were
written by the developer.

Compare with `STEEP_ERB_CONVENTION` (already working):

```ruby
if ENV["STEEP_ERB_CONVENTION"] && (erb_class = ErbSelfTypeResolver.resolve(path))
  source_code = source_code + "\n# @type self: #{erb_class}"
end
```

---

## Annotation rules

| Module type | Injected annotations |
|---|---|
| `extend ActiveSupport::Concern` present | `# @type self: singleton(IncludingClass) & singleton(ModuleName)` + `# @type instance: IncludingClass & ModuleName` |
| Regular `module` (no concern) | `# @type instance: IncludingClass & ModuleName` only |

**Why no `@type self:` for regular modules?**
In a concern, `included do` / `class_methods do` blocks run in the class singleton context,
so Steep needs `@type self:` to resolve class-level calls. In a plain module, `self` inside
instance methods is already the including instance — `@type instance:` covers it completely.

---

## Algorithm (`ModuleSelfTypeResolver.annotate`)

```
given path + source_code:
  derive module_name from path convention
    app/models/post/notifiable.rb → Post::Notifiable
  return source_code unchanged if:
    - not under app/models/
    - module_name has no namespace (Strategy B not supported yet — see below)
    - source_code already contains "@type self: ... ModuleName"  (idempotent)
  including_class = module_name.split("::")[0..-2].join("::")
  is_concern = source_code.include?("extend ActiveSupport::Concern")
  if is_concern:
    insert after `extend ActiveSupport::Concern` line:
      # @type self: singleton(IncludingClass) & singleton(ModuleName)
      # @type instance: IncludingClass & ModuleName
  else:
    insert after `module ModuleName` line:
      # @type instance: IncludingClass & ModuleName
  return modified source_code
```

---

## Including class resolution

**Strategy A — namespace convention** (handles ~100% of standard Rails concerns):
- `Post::Notifiable` → `Post`
- `User::Recoverable` → `User`
- Derived directly from the file path — no file scanning needed.

**Strategy B — `include` scanning** (unnamespaced modules, not yet implemented):
- Scan all `app/models/**/*.rb` for `include ModuleName`
- Return the class that contains that call
- If multiple classes include it, join with ` & `
- Modules with no namespace and no includer found → skip (no annotation injected)

---

## Insertion point

**Concern** — insert immediately after the `extend ActiveSupport::Concern` line:

```ruby
module Post::Notifiable
  extend ActiveSupport::Concern
                                        ← blank line
  # @type self: singleton(Post) & singleton(Post::Notifiable)
  # @type instance: Post & Post::Notifiable
                                        ← blank line
  included do
```

**Plain module** — insert immediately after the `module ModuleName` opening line:

```ruby
module Post::Taggable
  # @type instance: Post & Post::Taggable
                                        ← blank line
  def tag_names
```

Indentation mirrors the `extend` line's indent (spaces or tabs preserved).

---

## Idempotency

Before any insertion, check:
```ruby
source_code.match?(/@type self:.*#{Regexp.escape(module_name)}/)
```
If found → return source_code unchanged. Re-running or re-parsing is always safe.

---

## Current status

The `ModuleSelfTypeResolver` is implemented but **not yet validated**. Known gaps:

| Gap | Detail |
|---|---|
| `@type instance:` missing | Current code only injects `@type self:`, not `@type instance:` |
| Plain module annotation wrong | Current code injects `@type self:` for plain modules; should be `@type instance:` only |
| No tests | `ErbSelfTypeResolver` has `test/source/erb_self_type_resolver_test.rb`; `ModuleSelfTypeResolver` has none |
| Strategy B not implemented | Unnamespaced modules are silently skipped |

---

## Work remaining

1. Fix `inject_after_extend` to also inject `# @type instance:`
2. Fix `inject_after_module_line` to inject `# @type instance:` instead of `# @type self:`
3. Add `test/source/module_self_type_resolver_test.rb` covering:
   - Concern with namespace → both annotations injected
   - Plain module with namespace → only `@type instance:` injected
   - Already annotated file → no change (idempotent)
   - File outside `app/models/` → no change
   - Module without namespace → no change (Strategy B not yet supported)
4. Run `steep check` against dummy app with `STEEP_MODULE_CONVENTION=1` to validate end-to-end
5. (Optional) Implement Strategy B for unnamespaced modules

---

## Edge cases

| Scenario | Handling |
|---|---|
| Module without namespace (`module Taggable`) | Skipped — Strategy B not yet implemented |
| `extend ActiveSupport::Concern` inside `included do` | Not a top-level extend; `source_code.include?` is a simple string check and would still match — needs tightening if this is a real concern |
| Module already annotated | Skip (idempotent) |
| Custom indentation (tabs vs spaces) | Mirrors indent from the `extend` line |
| Multiple classes include the same module | Not handled until Strategy B is implemented |
