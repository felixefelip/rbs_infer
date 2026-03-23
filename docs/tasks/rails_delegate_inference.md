# Rails `delegate` RBS Inference

## Background

`delegate :email, to: :user, prefix: true` in `Post` should generate:

```rbs
def user_email: () -> String
```

The method name depends on the `prefix:` option, the return type comes from resolving `User#email` via RBS/source analysis, and `allow_nil: true` makes the return type nilable.

## Changes needed (4 files to edit, 1 expectation to update)

### 1. `ClassMemberCollector` — parse `delegate` calls

**File:** `lib/rbs_infer/class_member_collector.rb`

- Add a `DelegateInfo` struct: `Struct.new(:methods, :target, :prefix, :allow_nil)`
- Add `@delegates` array and `attr_reader :delegates`
- Add `when :delegate` branch in `visit_call_node`
- Implement `extract_delegates(node)` private method that:
  - Extracts symbol arguments (`:email`, `:name`, etc.) as the delegated method names
  - Extracts `to:` keyword → the target association (e.g., `:user`)
  - Extracts `prefix:` keyword → `true` (use target name), a symbol (custom prefix), or `nil`/`false`
  - Extracts `allow_nil:` keyword → boolean
  - Pushes a `DelegateInfo` into `@delegates`

### 2. `Analyzer` — resolve delegate types and add as members

**File:** `lib/rbs_infer/analyzer.rb`

- In `parse_target_class`, capture `visitor.delegates` alongside `visitor.members`
- Add a new private method `resolve_delegate_methods(delegates, target_members)` that for each `DelegateInfo`:
  1. **Resolves the target class** from the `to:` symbol:
     - Check `belongs_to` / `has_one` associations in the parsed AST (look for `:user` → `User`)
     - Fallback: classify the symbol (`:user` → `"User"`, `:account` → `"Account"`)
  2. **For each delegated method**, resolves its return type via `method_type_resolver.resolve(target_class, method_name)`
  3. **Computes the generated method name** based on `prefix:`:
     - `prefix: true` → `"#{target}_#{method}"` (e.g., `user_email`)
     - `prefix: :author` → `"author_#{method}"`
     - no prefix → same as original method name
  4. **Handles `allow_nil:`** — if `true`, makes the return type nilable (append `?`)
  5. **Creates `Member` structs** with `kind: :method` and appends them to `target_members`
- Call `resolve_delegate_methods` in `generate_rbs` after `parse_target_class` and after the `method_type_resolver` is available (before the final `rbs_builder.build` call)

### 3. `RbsBuilder` — no changes needed

Since delegate methods will be added as regular `Member` structs with `kind: :method`, the existing `RbsBuilder#build` will emit them as `def method_name: () -> Type` automatically.

### 4. Tests

- **Unit test** — add specs in `spec/lib/rbs_infer/class_member_collector_spec.rb` for delegate parsing (various `prefix:` and `allow_nil:` combinations)
- **Unit test** — add section in `spec/lib/rbs_infer/analyzer_spec.rb` to test that delegate methods appear in generated RBS with correct types
- **Integration** — update `spec/expectations/post.rbs`: add `def user_email: () -> String` to the expected output

### 5. Expectation update

**File:** `spec/expectations/post.rbs`

Add the line:

```rbs
def user_email: () -> String
```

## Edge cases to handle

| Scenario | Example | Generated |
|---|---|---|
| No prefix | `delegate :email, to: :user` | `def email: () -> String` |
| `prefix: true` | `delegate :email, to: :user, prefix: true` | `def user_email: () -> String` |
| Custom prefix | `delegate :email, to: :user, prefix: :author` | `def author_email: () -> String` |
| Multiple methods | `delegate :name, :email, to: :user` | `def name` + `def email` |
| `allow_nil: true` | `delegate :email, to: :user, allow_nil: true` | `def email: () -> String?` |
| Unresolvable target | `delegate :foo, to: :bar` | `def foo: () -> untyped` |

## Execution order

1. Implement `extract_delegates` in `ClassMemberCollector`
2. Implement `resolve_delegate_methods` in `Analyzer` + wire it into `generate_rbs`
3. Update expectations file
4. Run tests to verify
