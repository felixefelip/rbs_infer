# Module Self-Types via Sidecar (planned refactor)

## The problem

For concerns and modules, Steep needs `# @type self:` / `# @type instance:` annotations so
that a method returning `self`, or a call to the including class, type-checks. Today the
fork's `Steep::Source::ModuleSelfTypeResolver` injects these during `Source.parse` by
**deriving the module name from the file path**:

```ruby
# app/models/search/record/sqlite.rb
relative    = "search/record/sqlite"
module_name = relative.split("/").map { |s| camelize(s) }.join("::")
# camelize("sqlite") => "Sqlite"  →  Search::Record::Sqlite   ❌  (real name: SQLite)
```

Two things are wrong here:

1. **Casing bug.** Naive `camelize` mis-cases acronyms and any inflector-customized name
   (`SQLite`, `OAuth`, `HTTP`). The path `sqlite` simply doesn't carry the real casing. A
   concern method returning `self` then gets annotated against a type that doesn't exist
   (`Search::Record::Sqlite`), which RBS/Steep reject. (We can't fix this with the app's
   inflector either: the custom acronyms live in `config/initializers/inflections.rb`, which
   only runs when Rails boots — and the `rbs_infer` CLI deliberately doesn't boot Rails.)

2. **Layering smell (the real driver).** `ModuleSelfTypeResolver` hardcodes Rails
   conventions inside a framework-agnostic type checker: `MODELS_PREFIX = "app/models/"`,
   `HELPERS_PREFIX`, `CONTROLLER_CONCERNS_PREFIX`, `extend ActiveSupport::Concern` detection,
   `including_class = "ApplicationController"`. Steep should not know about Rails.

The casing bug is just the symptom that exposed the layering problem.

## The split

Separate **what to inject** from **where to inject**:

| Responsibility | Today | After |
|---|---|---|
| Module name, including-class, is-concern, path conventions | Steep (Rails-isms) | **rbs_infer** (Rails-aware) |
| Place the `@type` comment at the right AST scope | Steep | **Steep** (generic) |

The **placement** logic (`find_target_scope` / `insert_in_body` / `append_at_end`) is
legitimately Steep's — it's about how Steep's parser attaches `@type` comments to scopes
(top-level → append at EOF; nested module → insert inside the body, else the comment binds
to the wrong scope). That **stays**. Everything else **leaves** Steep.

## The sidecar

Same pattern as the existing `.steep_contracts.yml` / `.steep_callbacks.yml`, keyed by
**relative path** (because `Source.parse` receives `path`):

```yaml
# sig/generated/.steep_module_self_types.yml
"app/models/search/record/sqlite.rb":
  anchor: "SQLite"          # leaf constant, so Steep can locate the scope
  annotations:
    - "# @type self: singleton(Search::Record) & singleton(Search::Record::SQLite)"
    - "# @type instance: Search::Record & Search::Record::SQLite"
```

Steep receives the **finished comment lines** plus an **anchor** to locate the scope. It
does not know what a concern, a helper, or Rails is — it just places strings.

## Steep side (generic, framework-agnostic)

New module `Steep::Source::ModuleSelfTypes`:

- `load(base)` — read the sidecar once (memoized), mirroring `Callbacks.load`.
- `inject(source_code, annotations:, anchor:)` — **placement only**, reusing
  `find_target_scope` / `insert_in_body` / `append_at_end` essentially unchanged.

`Source.parse` becomes:

```ruby
if path.to_s.end_with?(".rb") && (entry = ModuleSelfTypes.for(path))
  source_code = ModuleSelfTypes.inject(source_code, **entry)
end
```

**Deleted from Steep** (same PR — add + remove together, no temporary fallback):
`annotate` / `annotate_helper` / `annotate_controller_concern`,
`append_concern_annotations` / `append_module_annotation`, the three `*_PREFIX` constants,
`camelize`, and the per-file declared-name resolution.

**No sidecar entry → no injection.** Without the Rails-aware generator, Steep does not
invent Rails annotations — which is the correct framework-agnostic behavior.

## rbs_infer side (the owner)

New emitter (e.g. `RbsInfer::Extensions::Rails::ModuleSelfTypeGenerator` + a
`rbs_infer:module_self_types:all` task):

- walk `app/models`, `app/helpers`, `app/controllers/concerns`;
- extract the **declared FQN from the AST** (correct casing — the bug disappears here for
  free, from the same `@target_class` the analyzer already computes correctly);
- detect concern; compute the including class — and it **can do better** than Steep's
  hardcoded "namespace == including class": rbs_infer already scans call-sites for other
  inference, so it can find the real `include` site;
- write the sidecar.

**rbs_infer's own internal use:** `analyzer.rb` currently calls
`ModuleSelfTypeResolver.annotate` before its own Prism parse. It switches to calling the
generic Steep `ModuleSelfTypes.inject` with the entry it computed — the same computation
that feeds the sidecar. One source of truth feeding both consumers (rbs_infer's internal
`type_check` and external `steep check`).

## Ordering

The sidecar must exist before any `type_check`. rbs_infer already generates in stages, so it
writes the sidecar in an early pass (the info comes from the parse it already does) — the
same "generate sidecar, then check" flow the other sidecars use.

## Migration cost (honest)

Anyone running `STEEP_MODULE_CONVENTION=1 steep check` **standalone** (no generator) loses
the automatic annotation — they must generate the sidecar first. This is **intentional**
(it's the correct layer), and acceptable for the coordinated 3-repo fork.

## Rollout — 2 PRs

1. **Steep (one PR):** add `ModuleSelfTypes` (loader + generic injector), switch
   `Source.parse` to read the sidecar, and remove the old `ModuleSelfTypeResolver` with all
   its Rails-isms.
2. **rbs_infer (one PR):** add the emitter + task, write the sidecar, switch `analyzer.rb`
   to the generic injector.

Between merges there's a short window where concerns get no annotation (Steep merged, sidecar
not yet emitted) — concern self-types regress until the rbs_infer PR lands. To avoid even
that window, land the rbs_infer emitter first (the old Steep ignores the sidecar and keeps
using the path), then the Steep PR that starts reading it.
