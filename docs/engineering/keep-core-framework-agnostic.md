## Keep the core framework- and gem-agnostic — push DSL knowledge into extensions

The core inference pipeline (`AST::*`, `Inference::*`, `Signatures::*`) must not know
any specific gem or framework DSL. It reads *plain Ruby* — `class`, `module`, `def`,
`class << self`, assignments, calls. The moment a name like `class_methods`, `on_load`,
`enumerize`, `mount_uploader`, `belongs_to`, or `ActiveSupport::Concern` appears in a
`when`/`if` inside `lib/rbs_infer/{ast,inference,signatures}`, the core has learned a
framework — that's the bug, not the feature.

Framework knowledge belongs in **`lib/rbs_infer/extensions/`**, wired through one of the
existing plugin seams so the core stays oblivious:

- **`RbsInfer::Project::SourceExpanders`** — desugar a macro into plain Ruby *before* the
  parse, so the generic pipeline sees ordinary nodes. This is the right tool whenever the
  DSL is expressible as plain Ruby the core already handles. Examples:
  `CurrentAttributesExpander`, `OnLoadExpander`, `ClassMethodsExpander`
  (`class_methods do … end` → `module ClassMethods … end`).
- **`RbsInfer::Project::SelfTypeAnnotators`** — inject `@type self:` / `@type instance:`
  comments into the source *after* expansion but *before* the parse, for cases that aren't a
  plain-Ruby desugaring but a self-type the pipeline (and Steep, as the return-type oracle)
  must see — e.g. a concern's host-class self, or the includer-singleton self of a desugared
  `module ClassMethods`. An annotator implements
  `self_type_entries(path:, module_name:, source:) -> [{ "anchor", "annotations" }]`; the core
  places each via Steep's generic `Source::ModuleSelfTypes.inject`, never naming the extension.
  Examples: `ModuleSelfTypeAnnotator`, `ClassMethodsImplements`.
- **Generators** (`enumerize/`, `rails/custom_generator.rb`, `erb_convention_generator.rb`,
  `devise/`, `carrierwave/`) — emit standalone sidecar RBS into a dedicated `sig/` dir via a
  rake task, never touching the core analysis of the source file.

All three seams let an extension register itself at require time; the core knows none of them.

Litmus test: *would this `when`/`if`/constant-name make sense for a gem that doesn't exist?*
If it only makes sense because Rails/ActiveSupport/some gem defines that method, it does not
belong in the core. Ask "can I desugar this DSL into plain Ruby an existing visitor already
understands?" — if yes, write a `SourceExpander`, don't special-case a visitor.

Why an expander beats a core special-case, even when the special-case is fewer lines:

- **Single source of truth** — the desugared `module ClassMethods` flows through the *same*
  owner/visibility/return-type machinery every other module uses. A core special-case has to
  re-derive (and keep in sync) what the generic path already does.
- **Self-gating and removable** — an expander gates on a cheap substring and no-ops
  otherwise; a non-Rails project pays nothing and the seam can be unregistered. A core
  `when :class_methods` fires for *every* file, forever.
- **Composability** — expanders chain; one's output feeds the next.

Real miss (felixefelip/rbs_infer#60): `class_methods do … end` support was first added by
teaching `LexicalScope`/`DefCollector`/`ClassMemberCollector` the `class_methods` call shape
directly — three core files now carrying an `ActiveSupport::Concern` concept. It was rewritten
as `ClassMethodsExpander`, a `SourceExpander` desugaring the block into a nested
`module ClassMethods`, which the core already attributes to a `ClassMethods` owner with zero
new core knowledge — identical RBS, core back to agnostic.

Real miss (felixefelip/rbs_infer#52, #60): the self-type injection for concerns was wired by
calling `Extensions::Rails::ModuleSelfTypeAnnotator` (and later `ClassMethodsImplements`)
*directly* from `Analyzer#load_and_parse_target` — the core naming two Rails extensions by
name. The litmus catches it: those names only make sense because Rails has `app/models`
conventions and `ActiveSupport::Concern`. It was rewritten as the
`RbsInfer::Project::SelfTypeAnnotators` seam: the annotators register at require time and the
analyzer calls `SelfTypeAnnotators.apply(...)` knowing none of them — same injected
annotations, core back to agnostic.
