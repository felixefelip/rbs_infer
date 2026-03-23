# RBS-Based Type Resolution — Remaining Refactors

Hardcoded type resolution patterns that could be replaced with RBS/Steep-based approaches.

## Context

We already replaced `extract_element_type` in three files (`caller_file_analyzer.rb`, `param_type_inferrer.rb`, `erb_convention_generator.rb`) to use `RbsDefinitionResolver#resolve_each_element_type` instead of hardcoded regex for `ActiveRecord_Associations_CollectionProxy` and `Array[X]`.

The items below follow the same principle: replace manual heuristics with RBS definitions.

---

## 1. Hardcoded `ARRAY_SELF_RETURN_METHODS` in `type_merger.rb`

**File:** `lib/rbs_infer/type_merger.rb` (line 7)

```ruby
ARRAY_SELF_RETURN_METHODS = %i[<< push append unshift prepend insert concat].to_set
```

**Problem:** Manually lists Array methods that return `self`. If a custom collection class defines `<<` differently, or if Array's API changes, this list silently goes stale.

**Approach:** Query RBS definitions for `Array` to determine which methods have return type `self` or `instance`. Could add a method to `RbsDefinitionResolver` like `methods_returning_self(class_name)` that inspects return types from `RBS::DefinitionBuilder`.

---

## 2. Manual gem name heuristics in `rbs_type_lookup.rb`

**File:** `lib/rbs_infer/rbs_type_lookup.rb` (lines 128–136, 185–191)

```ruby
gem_hints = []
parts.first(2).each do |part|
  gem_hints << part.downcase
  gem_hints << part.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
  gem_hints << part.gsub(/([a-z])([A-Z])/, '\1-\2').downcase
end
rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
```

**Problem:** Manually transforms class names (CamelCase → snake_case, kebab-case) to guess gem directory names under `.gem_rbs_collection/`. Fragile when gem naming doesn't follow these conventions.

**Approach:** Use `RBS::EnvironmentLoader` (already used in `SteepBridge`) which handles gem collection loading officially. It knows the actual gem-to-directory mappings from `rbs_collection.yaml`.

---

## 3. Manual hash/record type inference in `node_type_inferrer.rb`

**File:** `lib/rbs_infer/node_type_inferrer.rb` (lines 45–75)

```ruby
def self.infer_hash_type(node, known_types: {}, context_class: nil)
  # Manual heuristics: all symbol keys → record type, otherwise Hash[K, V]
end
```

**Problem:** Infers hash types purely from the literal's structure (all symbol keys → record type) without consulting what type the context expects. For example, `build(params: { name: "foo" })` could use the RBS definition of `build` to know that `params` expects `{ name: String }`.

**Approach:** Use bidirectional typing — when a hash is passed as an argument, look up the expected parameter type from RBS definitions to produce a more accurate type. This is a larger architectural change since it requires threading expected-type context through the inference pipeline.

---

## 4. Limited method chain resolution in `new_call_collector.rb`

**File:** `lib/rbs_infer/new_call_collector.rb` (lines 259–265)

```ruby
def resolve_method_chain(node)
  return nil unless @method_type_resolver
  receiver_type = resolve_receiver_type(node.receiver)
  return nil unless receiver_type && receiver_type != "untyped"
  @method_type_resolver.resolve(receiver_type, node.name.to_s)
end
```

**Problem:** Only resolves one level of `receiver.method()`. For chains like `user.posts.where(published: true).first`, each step needs to resolve through RBS to get the next type. Currently falls back to `untyped` for deeper chains.

**Approach:** `resolve_method_chain` already recurses via `resolve_receiver_type` → `resolve_method_chain`, so multi-level chains should work in theory. The real gap is that `resolve_receiver_type` doesn't handle all receiver node types (e.g., `SelfNode` returns `nil`). Improving `resolve_receiver_type` to handle `SelfNode` (using caller class context) and adding `ConstantReadNode`/`ConstantPathNode` support for class method chains would cover more cases without a full rewrite.
