# Rails `delegate` RBS Inference

## Context

`Post` already has:

```ruby
delegate :email, to: :user, prefix: true
```

The current `post.rbs` snapshot has no `user_email` method — the `delegate` call is silently ignored.
The goal is to emit:

```rbs
def user_email: () -> String
```

The method name depends on `prefix:`, the return type comes from resolving `User#email` via
`MethodTypeResolver`, and `allow_nil: true` makes the return type nilable.

---

## Implementation plan

### 1. `ClassMemberCollector` — detect `delegate` calls

**File:** `lib/rbs_infer/class_member_collector.rb`

The `visit_call_node` method already switches on `node.name` for `:attr_accessor`, `:include`,
`:extend`, etc. Add a `when :delegate` branch that calls a new private method `extract_delegates`.

Because type resolution requires `MethodTypeResolver` (not available here), store raw delegate
metadata in a new `@delegates` array and expose it via `attr_reader`:

```ruby
DelegateInfo = Struct.new(:methods, :target, :prefix, :allow_nil, keyword_init: true)

attr_reader :members, :delegates, :superclass_name, :is_module

def initialize(comments:, lines:)
  # ...existing...
  @delegates = []
end
```

`extract_delegates(node)` should parse:
- Symbol arguments → delegated method names (e.g. `:email`, `:name`)
- `to:` keyword → target name as string (e.g. `"user"`)
- `prefix:` keyword → `true`, a symbol value (custom prefix), or `nil`/`false`
- `allow_nil:` keyword → boolean

```ruby
def extract_delegates(node)
  return unless node.arguments

  args = node.arguments.arguments
  method_names = args.select { |a| a.is_a?(Prism::SymbolNode) }.map(&:value)
  return if method_names.empty?

  kwargs = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
  return unless kwargs

  target = nil
  prefix = nil
  allow_nil = false

  kwargs.elements.each do |assoc|
    next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
    case assoc.key.value
    when "to"
      target = assoc.value.is_a?(Prism::SymbolNode) ? assoc.value.value : nil
    when "prefix"
      prefix = case assoc.value
               when Prism::TrueNode then true
               when Prism::SymbolNode then assoc.value.value
               end
    when "allow_nil"
      allow_nil = assoc.value.is_a?(Prism::TrueNode)
    end
  end

  return unless target

  @delegates << DelegateInfo.new(
    methods: method_names,
    target: target,
    prefix: prefix,
    allow_nil: allow_nil
  )
end
```

---

### 2. `Analyzer` — resolve delegate types and inject members

**File:** `lib/rbs_infer/analyzer.rb`

**2a. Capture delegates from the visitor**

In `parse_target_class` (line 190), store `visitor.delegates`:

```ruby
def parse_target_class
  visitor = ClassMemberCollector.new(comments: @parsed_target.comments, lines: @parsed_target.lines)
  @parsed_target.tree.accept(visitor)
  @superclass_name = visitor.superclass_name
  @is_module = visitor.is_module if @is_module.nil?
  @delegates = visitor.delegates   # ← add this
  visitor.members
end
```

**2b. Add `resolve_delegate_methods`**

Call it inside `generate_rbs` right after `parse_target_class` and before `rbs_builder.build`:

```ruby
target_members = parse_target_class
resolve_delegate_methods(target_members)   # ← add here
```

Implementation:

```ruby
def resolve_delegate_methods(target_members)
  return if @delegates.nil? || @delegates.empty?

  @delegates.each do |info|
    # Resolve target class: :user → "User", or look up belongs_to in members
    target_class = info.target.split("_").map(&:capitalize).join

    info.methods.each do |method_name|
      return_type = method_type_resolver.resolve(target_class, method_name) || "untyped"
      return_type = "#{return_type}?" if info.allow_nil && !return_type.end_with?("?")

      generated_name = case info.prefix
                       when true    then "#{info.target}_#{method_name}"
                       when String  then "#{info.prefix}_#{method_name}"
                       else              method_name
                       end

      target_members << Member.new(
        kind: :method,
        name: generated_name,
        signature: "#{generated_name}: () -> #{return_type}",
        visibility: :public
      )
    end
  end
end
```

> `method_type_resolver` is already memoized in `Analyzer` — no extra wiring needed.
> `RbsBuilder` already emits `:method` members as `def name: sig` — no changes needed there.

---

### 3. Expectation update

**File:** `spec/expectations/models/post.rbs`

Add:

```rbs
def user_email: () -> String
```

The line should appear after the `include` statements and before the first `def`, following the
order in which `target_members` is built (delegates are appended after the original members).

---

### 4. Tests

**Unit — `spec/lib/rbs_infer/class_member_collector_spec.rb`**

Add a describe block for `delegate` parsing covering:
- Basic: `delegate :email, to: :user` → `DelegateInfo(methods: ["email"], target: "user", prefix: nil, allow_nil: false)`
- `prefix: true` → `prefix: true`
- Custom prefix: `prefix: :author` → `prefix: "author"`
- Multiple methods: `delegate :name, :email, to: :user`
- `allow_nil: true` → `allow_nil: true`

**Integration — `spec/integration/rails_dummy_spec.rb`**

The existing `"Post model matches expected RBS"` snapshot test will catch regressions
automatically once the expectation file is updated.

---

## Edge cases

| Scenario | Input | Generated |
|---|---|---|
| No prefix | `delegate :email, to: :user` | `def email: () -> String` |
| `prefix: true` | `delegate :email, to: :user, prefix: true` | `def user_email: () -> String` |
| Custom prefix | `delegate :email, to: :user, prefix: :author` | `def author_email: () -> String` |
| Multiple methods | `delegate :name, :email, to: :user` | `def name` + `def email` |
| `allow_nil: true` | `delegate :email, to: :user, allow_nil: true` | `def email: () -> String?` |
| Unresolvable target | `delegate :foo, to: :bar` | `def foo: () -> untyped` |
| Namespaced target | `delegate :slug, to: :post_tag` | classifies as `PostTag` |

---

## Execution order

1. Add `DelegateInfo` struct and `extract_delegates` to `ClassMemberCollector`
2. Capture `@delegates` in `Analyzer#parse_target_class`
3. Implement `resolve_delegate_methods` and call it in `generate_rbs`
4. Update `spec/expectations/models/post.rbs`
5. Add unit specs in `class_member_collector_spec.rb`
6. Run `bundle exec rspec spec/integration/rails_dummy_spec.rb` to verify
