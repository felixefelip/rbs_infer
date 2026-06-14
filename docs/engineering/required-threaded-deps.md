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
