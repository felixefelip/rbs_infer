# `belongs_to :x, default:` — rbs_infer ↔ steep#54 contract

Interface spec between the **generation side** (`rbs_infer`, this repo) and the
**consuming side** ([`felixefelip/steep#54`](https://github.com/felixefelip/steep/pull/54)),
for the *Forma 2* direction agreed on
[rbs_infer#72](https://github.com/felixefelip/rbs_infer/issues/72#issuecomment-4880400678).

Status: **draft / design**. This document is the source of truth for what each
side emits and expects; implement against it, and evolve it (not the code) when
the boundary changes.

---

## 1. Problem & goal

A required `belongs_to :post` is typed `Post?`, so a `belongs_to :owner, default:
-> { post.user }` trips `steep check`:

```
app/models/assignment.rb:19: Type `(::Post | nil)` does not have method `user`
```

Runtime never raises when the record is built through `post.assignments` (which
sets `post`). We want to **remove that false positive where construction proves
`post` is set**, and keep it where it doesn't — using **plain-Ruby inference as
much as possible**, reserving Steep-fork contract features for what genuinely
can't be expressed as inference.

Forma 2 = the pseudo-code carries the **real model names** and Steep checks the
**real app code** against it. The decision "safe vs unsafe" comes from Steep's
normal call resolution over real code, not from rbs_infer scanning/reproducing
call-sites.

---

## 2. Roles

| | rbs_infer (this repo) | steep#54 (fork) |
|---|---|---|
| Emits pseudo-code definitions (real names) | ✅ | consumes |
| Emits RBS overrides (association return type) | ✅ | consumes |
| Emits metadata + source-map | ✅ | consumes |
| Loads defs into the app's check environment | — | ✅ |
| Reconciles RBS with rbs_rails output | defines the override; — | applies it |
| Decides suppression from real-code construction resolution | — | ✅ |
| Remaps a pseudo-body diagnostic to the real `default:` span | provides the map | ✅ applies |

Guiding split: **rbs_infer produces artifacts; steep#54 makes the
whole-program decision.** rbs_infer does *not* scan call-sites in Forma 2.

---

## 3. Principle — contract-free by construction

rbs_infer **guarantees** that every pseudo construction body routes the
`default:` deref through a **local variable** that is non-nil on the safe path,
so vanilla Steep narrowing types it with **no** precondition/postcondition
machinery. (Even attribute-write narrowing `record.post = x; record.post` is a
fork feature — so the deref goes through a *local*, never `self.post`.)

steep#54 **guarantees** it checks these bodies with ordinary narrowing and does
not require any contract sidecar for them.

Validated end-to-end (vanilla narrowing, zero contracts inferred):

| construction | `post` inferred | body diagnostics |
|---|---|---|
| `post = @owner` (non-nil local) | `Post?` | none |
| `post = record.post` (nilable local) | `Post?` | `(Post \| nil) does not have method user` |

---

## 4. Artifacts rbs_infer emits

All under `sig/generated/`, regenerated every run (self-gating: emitted only
when ≥1 model declares a `belongs_to ..., default:` lambda).

### 4.1 Pseudo-code definitions — `sig/generated/.steep_belongs_to_default/*.rb`

One file per contributing class, **real names**, reopening the model and
defining the association proxy as a **subclass of the real `CollectionProxy`**
(so `where/each/count/…` keep resolving — blast radius contained to
`create!/new/build`).

```ruby
# Post.rb — reopen: point `assignments` at our proxy
class Post
  def assignments
    PostAssignmentsProxyPseudoCode.new(self)
  end
end
```

```ruby
# PostAssignmentsProxyPseudoCode.rb — safe construction, contract-free deref
class PostAssignmentsProxyPseudoCode < ActiveRecord::Associations::CollectionProxy
  def initialize(owner)
    @owner = owner
  end

  def create!(attrs = nil)
    record = Assignment.new
    post = @owner              # the association owner, a non-nil Post
    record.post = post
    record.owner = post.user   # inlined default: deref — source-mapped (§4.3)
    record
  end
  # `new` / `build` / `create` follow the same shape
end
```

Requirements on this artifact:
- **Contract-free** (§3): the deref rides a non-nil local.
- **Blast-radius safe**: the proxy subclasses the real `CollectionProxy`; only
  the construction methods are overridden.
- **Parse-clean & self-contained** for the classes it defines (the real AR
  ancestors come from the app's own RBS at check time).

### 4.2 RBS overrides — `sig/generated/.steep_belongs_to_default.rbs`

The association getter's return type must point at the pseudo-proxy, else Steep
keeps resolving `@post.assignments.create!` to the real `CollectionProxy#create!`:

```rbs
class Post
  def assignments: () -> PostAssignmentsProxyPseudoCode
end

class PostAssignmentsProxyPseudoCode < ActiveRecord::Associations::CollectionProxy[Assignment]
  def initialize: (Post owner) -> void
  def create!: (?untyped attrs) -> Assignment
  # new / build / create ...
end
```

> ⚠️ **Open — RBS reconciliation (§8.1).** This `Post#assignments` override
> collides with the rbs_rails-generated signature; #54 (or the rbs_infer/rbs_rails
> emission order) must **replace**, not add, that entry.

### 4.3 Metadata + source-map — `sig/generated/.steep_belongs_to_default.yml`

Per belongs_to-default model: the suppression target (the real `default:` span),
the safe construction entry points, and the deref map.

```yaml
models:
  - model: "Assignment"

    # The native diagnostic to suppress / re-surface. Steep flags this span
    # from checking the real `default:` lambda.
    default_lambda:
      path: "app/models/assignment.rb"
      line: 19
      column: 55
      length: 9

    # The pseudo methods #54 treats as PROVEN-SAFE construction entry points.
    # A real call resolving to one of these (with a clean body) counts as a
    # safe construction of the model.
    safe_constructions:
      - receiver_type: "Post"            # the real receiver's class
        association: "assignments"       # via `Post#assignments`
        methods: ["create!", "create", "new", "build"]
        pseudo_type: "PostAssignmentsProxyPseudoCode"

    # Inlined-deref (pseudo) → real default: span. Used to re-surface a body
    # diagnostic at the real lambda if a "safe" body ever errors.
    deref_map:
      - pseudo_file: "PostAssignmentsProxyPseudoCode.rb"
        pseudo_line: 12
        default_line: 19    # keyed back into default_lambda above
```

---

## 5. steep#54 semantics

### 5.1 Loading & reconciliation
- Add `sig/generated/.steep_belongs_to_default/*.rb` to the checked sources and
  `.steep_belongs_to_default.rbs` to the signatures for the app target.
- Apply the association-getter override as a **replacement** of the rbs_rails
  signature (§8.1).

### 5.2 Suppression rule (the core decision)
For each `model` entry, while checking the real app:

1. Identify every construction that **runs the default** for that model — i.e.
   a `create` / `create!` / (`new` + `save`) / `save` on it.
2. A construction is **proven-safe** iff it resolves to a `safe_constructions`
   entry whose pseudo body type-checks **clean**.
3. **Suppress** the native diagnostic at `default_lambda` **iff every**
   default-running construction of the model that the real app reaches is
   proven-safe. Otherwise **keep** it (the unsafe/unmodeled path leaves the
   native error in place — sound by default).

> Note: this makes suppression a whole-program property computed by #54 from
> real-code resolution. rbs_infer supplies the *safe* pseudo paths; anything not
> matching them is "not proven safe" ⇒ no suppression.

### 5.3 Diagnostic remapping
If a `safe_constructions` pseudo body itself errors on its inlined deref
(should not happen for a genuine safe path, but e.g. a malformed default),
remap that diagnostic from `pseudo_file:pseudo_line` to the `default_lambda`
span via `deref_map`, and do **not** suppress.

---

## 6. Worked example (Assignment / Post)

Real app:
```ruby
# app/controllers/posts/assignments_controller.rb
@post.assignments.create!(assignment_params)     # safe
```

1. rbs_infer emits `Post.rb`, `PostAssignmentsProxyPseudoCode.rb` (§4.1), the RBS
   override (§4.2), and the metadata (§4.3).
2. #54 loads them; `@post.assignments` now types as `PostAssignmentsProxyPseudoCode`,
   so `.create!` resolves to the pseudo body → checked clean (contract-free).
3. Every default-running construction of `Assignment` the app reaches is that
   safe path ⇒ #54 **suppresses** `app/models/assignment.rb:19`.

If instead the app also had `Assignment.create!(assignment_params)` (direct,
`post` not established): that construction does **not** resolve to a
`safe_constructions` entry ⇒ not proven-safe ⇒ #54 **keeps**
`app/models/assignment.rb:19`. Sound.

---

## 7. Soundness

Suppression happens **only** when every default-running construction the app
reaches is a proven-safe pseudo path (post established through the association
owner, checked by pure narrowing). Any unmodeled or direct path is "not proven
safe" and leaves the native diagnostic in place. So the false positive is
removed **only where construction actually proves `post` is set** — never
blindly.

---

## 8. Open questions

### 8.1 RBS reconciliation with rbs_rails (§4.2) — *decision pending; recommendation below*

**Empirical findings** (from the dummy's `sig/rbs_rails/app/models/post.rbs`):

- `Post#assignments` is emitted **in the class body**
  (`class ::Post … def assignments: () -> ::Assignment::ActiveRecord_Associations_CollectionProxy`),
  **not** in an included module — so a class-body override can't "shadow" it; it
  becomes a **duplicate method** error.
- The proxy `::Assignment::ActiveRecord_Associations_CollectionProxy` is
  **per-element (shared across owners)**, so it **carries no owner type** — we
  can't type `owner` as `Post` on it.
- That proxy **already defines** `create! / create / build` (returning
  `::Assignment` / `::Assignment::Validated`) and includes
  `ActiveRecord::Relation::Methods[…, ::Assignment::Validated]` — i.e. the
  `Validated`/postcondition machinery we want to move away from already lives here.

**Options:**

- **(a)** #54 replaces the rbs_rails association entry at load. Simple for
  rbs_infer, but Steep learns rbs_rails specifics (less clean, more fragile).
- **(b)** rbs_infer post-processes the rbs_rails `.rbs` in place. Keeps it all in
  RBS, but mutates another generator's output and is clobbered on regeneration.
- **(c) — recommended.** The `felixefelip/rbs_rails` fork emits an
  **owner-specific proxy** (e.g. `Post_Assignments_CollectionProxy`, carrying the
  owner type) returned by `assignments`; rbs_infer supplies only the
  **contract-free body**. Resolves the conflict at the source (no duplicate),
  **gives the owner type** the shared proxy lacks, keeps Steep generic, and
  **supersedes the `Validated`/postcondition markers** for that association —
  aligned with dropping the rbs_rails contract machinery. Cost: a 3-repo change
  (the split the project already assumes).

> This question **gates the repo footprint**: (a)/(b) keep it a two-repo change
> (rbs_infer ↔ steep#54); (c) makes it three (incl. `felixefelip/rbs_rails`).

### 8.2 What counts as "runs the default" (the trigger set) — *decision pending; recommendation below*

The `belongs_to default:` runs in `before_validation` (so on `valid?`, `save`,
`create`, `update`, …). But contract-free suppression can only resolve locally
what **builds and persists in the same expression**.

- **v1 = `create` / `create!` only** (class-level and association-level) —
  *recommended*. Atomic build+persist, resolvable by pure inference. `new`/`build`
  alone don't persist (don't run the default). `new/build` + a later `save`, and
  bare `save`/`update`/`valid?` on a record built elsewhere, are **left to the
  native check** (no suppression ⇒ **sound**, just more conservative).
- **Broader set** (`new`+`save`, bare `save`/`update`/`valid?`): covers split
  build-then-save, but the fact crosses a method boundary ⇒ needs the contract
  machinery — exactly what we're avoiding. Revisit later only if necessary.

### Remaining

3. **Direct construction with a non-nil literal** (`Assignment.create!(post:
   some_post)`). Is this a `safe_constructions` entry too (post established by a
   literal kwarg), or left to the native check? Likely the former — extend the
   schema with a `literal_belongs_to` variant.
4. **Multiple `default:` on one model / defaults that deref more than one
   belongs_to.** `deref_map` is already a list; confirm the suppression rule is
   per-lambda-span, not per-model.
5. **Faithful growth of the proxy.** Which AR methods beyond `create!/new/build`
   ever need overriding, and how do we keep the subclass from leaking new false
   positives as the pseudo model grows (§ the accepted "faithful" cost).
6. **Reachability granularity in #54.** "Every construction the app reaches" —
   does #54 compute this during the normal check pass, or does it need a
   dedicated construction-resolution pass? Impacts #54 feasibility.

---

## 9. Sequencing

1. **This doc** — agree the artifacts, schemas and suppression rule. ← *here*
2. Resolve the blocking open questions (§8.1, §8.2) — enough to make both sides
   implementable.
3. rbs_infer: implement emission of §4.1–§4.3 (redirects PR #73 from the Forma 1
   isolated generator to this). Snapshot-test the emitted artifacts.
4. steep#54: implement §5 (load, suppress, remap).
5. End-to-end: the dummy `Assignment` + `Posts::AssignmentsController` — the
   `(::Post | nil)` baseline clears on the safe path; a direct-construction
   fixture keeps it.
