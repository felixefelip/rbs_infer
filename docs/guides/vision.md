# Vision: Automatic Type Signatures for the Ruby Ecosystem

## The Problem

Ruby projects that adopt RBS and Steep face a cold-start problem: you need `.rbs` files to get type checking, but writing them manually for an existing codebase is tedious and error-prone. Most teams give up before reaching the point where Steep becomes useful.

## The Role of rbs_infer

**rbs_infer is an automatic RBS signature generator.** It analyzes your Ruby source code and produces `.rbs` files — no annotations required. It is **not** a type checker. It does not report errors or validate your code.

The type checker is **Steep**. Steep reads `.rbs` files and provides real-time diagnostics, hover types, autocomplete, and go-to-definition through its LSP server.

rbs_infer and Steep are complementary:

```
┌─────────────┐      generates       ┌────────────┐
│  rbs_infer   │  ──────────────────► │  .rbs files │
│  (generator) │                      └──────┬─────┘
└─────────────┘                              │
                                        reads │
                                              ▼
                                     ┌──────────────┐      LSP       ┌──────────┐
                                     │    Steep      │ ◄────────────► │  VS Code │
                                     │ (type checker)│               │  Editor  │
                                     └──────────────┘               └──────────┘
```

## Target Workflow

### 1. Initial Setup — Bootstrap signatures for an existing project

```bash
# Generate .rbs for the entire app
rbs_infer app/ --output-dir sig/generated

# Steep immediately works with the generated signatures
steep check
```

This eliminates the cold-start problem. A team can go from zero to type-checked in minutes.

### 2. Development — Keep signatures in sync on save

The ideal development flow is:

```
You edit user.rb → rbs_infer regenerates sig/generated/user.rbs → Steep LSP picks up the change → VS Code shows updated types
```

This can be achieved today with a file watcher:

```bash
# Using fswatch (macOS/Linux)
fswatch -o app/ lib/ | xargs -n1 -I{} rbs_infer app/ lib/ --output-dir sig/generated

# Using guard
# Guardfile
guard :shell do
  watch(%r{^(app|lib)/(.+)\.rb$}) do |m|
    `rbs_infer #{m[0]} --output-dir sig/generated`
  end
end
```

With the Steep VS Code extension running, you get:
- **Inline diagnostics** — type errors highlighted as you type
- **Hover types** — see inferred types on hover
- **Autocomplete** — method suggestions based on inferred types
- **Go-to-definition** — navigate to method definitions

### 3. CI — Validate types on every push

```yaml
# .github/workflows/typecheck.yml
name: Type Check
on: [push, pull_request]

jobs:
  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Generate RBS signatures
        run: bundle exec rbs_infer app/ lib/ --output-dir sig/generated
      - name: Type check
        run: bundle exec steep check
```

### 4. Gradual Adoption

rbs_infer produces types on a best-effort basis. Unknown types become `untyped`, which Steep treats permissively. This means:

- **Day 1**: Generate signatures, get partial type checking for free
- **Week 1**: Fix easy `untyped` gaps by adding manual `.rbs` overrides in `sig/`
- **Month 1**: Most of the codebase is typed, catching real bugs

Manual signatures in `sig/` always take precedence over generated ones in `sig/generated/`. You never have to fight the generator.

## Architecture

### What rbs_infer infers (and Steep alone does not)

| Capability | rbs_infer | Steep standalone |
|-----------|-----------|-----------------|
| `initialize` param types from call-sites | Yes — cross-file caller analysis | No |
| `attr_reader`/`attr_writer` types from `initialize` | Yes | No |
| Method return types | Yes — Prism AST + Steep as oracle | Requires `.rbs` |
| Parameter types from intra-class calls | Yes — argument flow analysis | Requires `.rbs` |
| Rails model associations/scopes | Yes — via rbs_rails integration | No |
| Concern/module inclusion | Yes | Requires `.rbs` |

### What Steep provides (and rbs_infer does not)

| Capability | Steep | rbs_infer |
|-----------|-------|-----------|
| Real-time error reporting | Yes — LSP server | No |
| Hover types in editor | Yes | No |
| Autocomplete | Yes | No |
| Type narrowing / flow-sensitive typing | Yes | No |
| Generic type validation | Yes | No |
| Overload resolution | Yes | No |

### The Feedback Loop

rbs_infer uses Steep internally as one of its inference passes (via `SteepBridge`). When the generated `.rbs` files are loaded into Steep's environment, Steep can resolve more types, which in turn lets rbs_infer produce better signatures on the next run.

```
Run 1: rbs_infer generates initial .rbs (many untyped)
Run 2: Steep sees the .rbs, resolves more types → rbs_infer uses Steep's results → fewer untyped
Run 3: Even fewer untyped
...converges
```

This iterative refinement means running rbs_infer 2-3 times on a fresh project progressively improves coverage.

## Future: VS Code Extension

The natural evolution is a VS Code extension that:

1. **Watches file changes** and runs rbs_infer incrementally on save
2. **Triggers Steep LSP reload** after regenerating signatures
3. **Shows generation status** in the status bar
4. **Provides commands** like "Generate RBS for this file" or "Generate RBS for workspace"

This would make the experience seamless — you write Ruby, and types appear automatically.

## Design Principles

- **Zero config** — works out of the box for standard Rails/Ruby projects
- **Non-invasive** — no annotations, no source code changes, no custom syntax
- **Best-effort** — unknown types are `untyped`, not errors. Coverage improves over time
- **Complementary** — enhances Steep, does not replace it
- **Incremental** — efficient enough to run on every save, not just in CI
