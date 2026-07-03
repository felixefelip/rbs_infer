# `belongs_to ..., default:` Nilable-by-Flow Inference

## The problem

A Rails `belongs_to` is typed nilable on the bare model (rbs_rails emits `post: Post?`),
because the association can be unset until saved. So a `default:` lambda that dereferences
another association trips Steep:

```ruby
class Assignment < ApplicationRecord
  belongs_to :post
  belongs_to :owner, class_name: "User", default: -> { post.user }
end
```

```
app/models/assignment.rb:19: Type `(::Post | nil)` does not have method `user`
```

Runtime never raises. An `Assignment` is only ever built through `post.assignments`
(which sets `post`), and `default:` runs in `before_validation`, so `post` is present when
the lambda runs. The generated RBS is already correct — the false positive is Steep's check
of the **real lambda**, not a missing type. This is the exact `(::Board | nil) does not have
method account` false positive from Fizzy.

## Why this is not a `SourceExpander`

The [`SourceExpander`](../engineering/keep-core-framework-agnostic.md) seam (e.g.
`CurrentAttributesExpander`) desugars for **rbs_infer's own inference** — its output is never
seen by the app's `steep check`. That works when the fix is "infer a type". Here the RBS is
already right; the problem is Steep's **check of the lambda**. So the expansion must be
**consumed by Steep** (via [felixefelip/steep#54](https://github.com/felixefelip/steep/pull/54)),
not fed to rbs_infer's parse. This lives in a **generator** that emits a sidecar, like the
module-self-types generator.

## The approach: emit `example.rb`-shaped Ruby (flow-based)

The [`example.rb` contract scenario](../../spec/integration/steep_scenarios_spec.rb) already
proves end-to-end that Steep's contract mechanism
([#51](https://github.com/felixefelip/steep/pull/51) explicit-receiver + attribute-write
narrowing, [#52](https://github.com/felixefelip/steep/pull/52) transitive closure) resolves
this shape:

```ruby
column = Column.new(...); column.board = board; column.save   # board non-nil → save chain enforces
```

`RbsInfer::Extensions::Rails::BelongsToDefaultGenerator` emits the AR flow **as that exact
shape** into a synthetic program, plus a source-map, for Steep (#54) to check and map back.

### Model side — `belongs_to default:` → lifecycle methods

```ruby
class RbsInferBelongsToDefaultAssignment
  attr_accessor :post, :owner
  def save; run_before_validation_callbacks; end
  def run_before_validation_callbacks; run_belongs_to_default_callbacks; end
  def run_belongs_to_default_callbacks
    self.owner = post.user          # lambda BODY inlined directly (not `-> {}.call`),
  end                               # so the contract inferrer sees the `post` deref
end
```

- `post` is set only from outside → rbs_infer infers `post: RbsInferBelongsToDefaultPost?`.
- The `post.user` deref inside a `save`-reachable method makes Steep infer the precondition
  `save requires self.post`.

### Caller side — `owner.assoc.create!(...)` → build + owner-setter + save

```ruby
# @post.assignments.create!(assignment_params)  ==>
def self.site_1
  record = RbsInferBelongsToDefaultAssignment.new
  owner  = RbsInferBelongsToDefaultPost.new       # the association OWNER
  record.post = owner                             # inverse belongs_to, non-nil (#51)
  record.save                                     # precondition satisfied → no error
end
```

The type flows through the **owner** of the association (not the FK, not `new`'s args):
`Post#assignments → owner : Post → record.post = owner → record.post : Post` (non-nil).

### Argument-typing rules

The desugared construction carries real nilability per attribute:

- **association attrs** → set from the owner (`record.post = owner`, non-nil);
- **literal kwargs** (`create!(owner: User.new)`) → set from the literal (narrows `owner`);
- **ParamsBag args** (`create!(assignment_params)`) → nothing set → those attrs stay nilable
  (correct: a params-sourced association can't be proven → the default's deref is still flagged).

### Synthetic-class naming

Every synthetic class carries the `RbsInferBelongsToDefault` prefix and is emitted at the
**top level** (not nested in a module — the analyzer's multi-class discovery only walks
top-level classes). Names are **camelCase, never underscored**: an underscore in a constant
currently defeats the analyzer's `.new`/external-setter resolution, which would type every
`attr_accessor` `untyped` and break the whole contract. Deref-receiver targets get a `raise`
stub per method called on them (`post.user` → `def user; raise; end`); the `⊥` return lets
deeper chains ride through while the first hop on a nilable receiver still errors.

## Soundness

Because it goes through the contract mechanism (not a blind `Validated` narrow), an
`Assignment.new.save` that does **not** establish `post` still errors — the false positive is
removed only where construction actually proves `post` is set.

## Sidecar contract (for felixefelip/steep#54)

Two files under `sig/generated/`, mirroring `.steep_module_self_types.yml`:

- **`.steep_belongs_to_default.rb`** — the synthetic `example.rb`-shaped program Steep adds to
  its check targets.
- **`.steep_belongs_to_default.yml`** — the source-map: a list of

  ```yaml
  - expanded_line: 20                      # the inlined `self.owner = post.user` line
    original_path: app/models/assignment.rb
    original_line: 19                       # the `belongs_to :owner, ..., default:` line
    original_column: 55                     # column of the lambda body `post.user`
    original_length: 9
  ```

Steep (#54) uses each entry to (a) **remap** any diagnostic it finds on `expanded_line` back to
the real `original_*` span, and (b) **suppress** its native check of that span (now covered by
the expansion). So: a safe association caller ⇒ expansion clean ⇒ native diagnostic suppressed;
an unsafe caller ⇒ expansion errors ⇒ mapped back to the real `default:` lambda.

## Wiring

- Rake task: `rake rbs_infer:belongs_to_default:all` (registered by the railtie).
- Makefile: `make rbs_infer_belongs_to_default` (and part of `make rbs_generators_all`).
- CLI: `bin/rbs_infer` emits both sidecars up front when running inside a Rails app.

## Layout

```
lib/rbs_infer/extensions/rails/
  belongs_to_default_generator.rb          # orchestrator + sidecar I/O
  belongs_to_default/
    reflection_scanner.rb                  # models → belongs_to/has_many/default: reflections
    construction_site_scanner.rb           # callers → association / direct construction sites
    expansion_builder.rb                   # reflections + sites → expanded Ruby + source-map
```
