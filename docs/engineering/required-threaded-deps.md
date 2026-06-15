## Make threaded dependencies required, not defaulted

When threading a new dependency (a registry, sidecar store, config object — anything that
must reach a downstream consumer) through a function with many callers, declare the new
kwarg **required**, not defaulted:

```ruby
def foo(..., registry:)      # a caller you forgot to wire fails loudly at load time
def foo(..., registry: nil)  # a caller you forgot to wire silently degrades
```

A default silently hides un-wired callers, turning a loud `ArgumentError` into a quiet
"the feature just doesn't fire" — one diagnostic session per missing site.

Litmus test: *if a caller forgets this, is the result silently wrong or loudly broken?*
Silent-wrong → required. Default only when some callers legitimately lack the dependency
and both behaviors are valid.

### Don't copy a neighbor's default

A new kwarg sitting next to already-defaulted ones is **not** license to default it too —
match the principle, not the surrounding signature. Those neighbors may themselves be debt:
run the litmus on each, and if every production caller already passes it, make them all
required (a unit spec that omitted them is a test-ergonomics concern — give it a small
builder helper with test-only defaults, keep the production API strict).

Real miss (felixefelip/rbs_infer#38): `RbsBuilder.new` was given a defaulted `type_params:`
mirroring its existing `namespace_classes:`/`is_module:` defaults. All three were in fact
passed by every production call-site, and omitting `type_params` is the textbook silent-wrong
case — it reopens a generic class without its parameters
(`class Array` instead of `class Array[unchecked out Elem]`), which RBS rejects with
`GenericParameterMismatchError` and which poisons the whole shared environment, not just the
one file. All three became required.
