# Method Signatures: Check Call Sites Before You Change Them

## The rule

> Before adding to or changing a method's signature — a default value, an optional
> keyword, a removed/reordered parameter — read every call site first. Let the
> *actual* callers, not a guess about future ones, decide the shape of the signature.

Defaults and optional kwargs are not free. Each one is a small decision that says
"this argument may legitimately be absent, and here is what happens when it is."
If no caller ever omits the argument, that decision is fiction: it adds a code
path nobody exercises, hides mistakes the language would otherwise catch, and can
silently route real calls down a fallback branch.

## Why an unnecessary default is a bug, not just clutter

A required keyword that is missing raises `ArgumentError` immediately — a loud,
local failure at the call site. A default turns that loud failure into one of two
quiet ones:

1. **It hides a missing argument.** A caller that *should* have passed the value
   but forgot now compiles and runs, taking the default instead. The bug surfaces
   far from its cause.
2. **It silently selects the wrong code path.** When the default value feeds a
   branch (a `nil` guard, a fallback lookup), an unintended caller skips the real
   logic and lands in the fallback — producing a plausible-but-wrong result rather
   than an error.

Both are worse than a crash, because a crash points at the line that's wrong.

## Worked example: `ClassNameExtractor`

The extractor picks which class/module a file declares. It had:

```ruby
def initialize(file_path: nil)
  @file_path = file_path
  # ...
end

def match_by_file_path
  return nil unless @file_path        # <- guard only reachable when nil
  expected = expected_leaf(@file_path)
  @candidates.find { |c| c[:name].split("::").last == expected }
end
```

The `file_path: nil` default looked harmless. But when we read the call sites,
**all five had a real file in scope** — and three of them were calling
`ClassNameExtractor.new` with no argument:

```ruby
caller_visitor = ClassNameExtractor.new          # caller_file_analyzer.rb — `file` in scope
extractor      = ClassNameExtractor.new          # dependency_sorter.rb     — `file` in scope
caller_ext     = ClassNameExtractor.new          # caller_file_cache.rb     — `file` in scope
```

The default wasn't enabling a real "no file" mode. It was letting three callers
**accidentally skip the basename-matching heuristic** (`match_by_file_path`) and
fall through to the generic `fallback_pick`. That's failure mode #2: silently
wrong selection for wrapper files like `class User; module Idade; ...; end; end`
in `user/idade.rb`.

The fix was driven entirely by the call sites:

```ruby
def initialize(file_path:)          # required — every caller already has one
  @file_path = file_path
end

def match_by_file_path
  expected = expected_leaf(@file_path)   # guard deleted: file_path is never nil
  @candidates.find { |c| c[:name].split("::").last == expected }
end
```

## The trap to avoid: don't trust the tests as the spec

The existing spec exercised `file_path: nil`, which *looked* like proof that the
"no file" mode was needed. It wasn't — the spec had simply been written to cover a
branch that the production code created, not a branch production code required.

**A test exercising a code path is not evidence that the path must exist.** Tests
can be over-fitted to the current implementation. When deciding whether a parameter
shape is necessary, the source of truth is the **production call sites**, not the
test suite. Update the tests to match the real contract; don't preserve a fictional
contract because a test happens to assert it.

(In that cleanup, the genuinely-real fallback path — `fallback_pick`, reached when a
file's basename matches no declared constant — was *kept*, and its test was rewritten
to pass a deliberately non-matching path instead of `nil`. Distinguish the dead
branch from the live one; only the `nil`-handling guard was dead.)

## Checklist before adding a default or optional kwarg

1. **Grep every call site.** `grep -rn "MethodName" lib spec` (or the call form).
2. **For each caller, ask: does it have the value in scope?** If they all do,
   the argument should be required.
3. **If some callers legitimately omit it,** confirm the default value drives the
   *intended* behavior for exactly those callers — and that the resulting branch is
   real production behavior, not test-only.
4. **Prefer a loud failure.** A required argument that raises at the wrong call site
   beats a default that hides the mistake.
5. **When you remove a default,** update the tests to supply the real argument; if a
   test relied on the absent-argument path, recreate the *production* scenario it was
   standing in for (e.g. a non-matching input), not the absence itself.

## Generalization

This is one instance of a broader discipline: **a method's signature is a contract
with its callers, so the callers — read in full — define the contract.** The same
"check the call sites first" reasoning applies to removing a parameter, reordering
positionals, widening a type, or making a previously-optional argument required.
Read the callers; let reality, not anticipation, shape the signature.
