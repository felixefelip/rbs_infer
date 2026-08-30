module RbsInfer::Inference
  # Resolves a constant used as a method ARGUMENT to its VALUE's RBS type
  # (felixefelip/rbs_infer#46). A class/module reference passed as an argument
  # (`foo(User)`) is the class OBJECT, so its type is `singleton(User)` — NOT
  # the instance `User`. A value constant (`CODE_LENGTH = 6`) resolves to its
  # value's type (`Integer`).
  #
  # Two tiers: the referencing source's own constants (`constant_types`,
  # precise — captures value `:casgn`s, not class defs), then the RBS
  # environment (`constant_type_from_env`: stdlib, gems, generated `sig/`) for
  # cross-file constants. A class/module isn't a value-constant declaration, so
  # `constant_type_from_env` misses it and we emit `singleton(<name>)`;
  # anything else unresolved → nil → caller emits `untyped`.
  class ConstantArgTypeResolver
    # caller_constant_types: bare-name => type for constants defined in the
    # referencing source (pass `{}` when there's no such source — the ERB path
    # and Steep-less collectors). Required so each call site states it rather
    # than inheriting a hidden default. steep_bridge nil disables the
    # cross-file tier → only same-file constants resolve; anything else → nil
    # (caller emits untyped), never a bare name (#56).
    def initialize(steep_bridge:, caller_constant_types:)
      @steep_bridge = steep_bridge
      @caller_constant_types = caller_constant_types
    end

    # Returns a valid RBS type (value type, or `singleton(...)` for a
    # class/module reference), or nil when nothing resolved — never an
    # unresolved value-constant name, which is invalid RBS and poisons the
    # shared env.
    def resolve(name:, namespace:)
      return nil if name.nil?

      bare = name.sub(/\A::/, "")
      short = bare.split("::").last

      same_file = @caller_constant_types[short] || @caller_constant_types[bare]
      return same_file if same_file

      # No env to classify against → nil (caller emits untyped). We must NEVER
      # return the bare name unclassified: it's invalid RBS for a value
      # constant and poisons the shared env (felixefelip/rbs_infer#56).
      return nil unless @steep_bridge

      # `name`, not `bare`: a leading `::` tells the env lookup to skip the walk
      # up `namespace`, and dropping it here made an absolute reference resolve
      # relative instead. `include ::Commentable` inside `Post::Commentable`
      # matched the enclosing module — a candidate the walk offers before the
      # top-level one — and typed the argument `singleton(Post::Commentable)`
      # (felixefelip/rbs_infer#295).
      value_type = @steep_bridge.constant_type_from_env(name, namespace: namespace)
      return value_type if value_type

      # The FULLY QUALIFIED name the env matched, not the one the call site wrote: a
      # relative `Slots` inside `class IncludedHook` means `::IncludedHook::Slots`, and
      # the type is emitted into a signature that may live in another namespace
      # entirely, where the written name would mean something else or nothing at all.
      fqn = @steep_bridge.class_or_module_name(name, namespace: namespace)
      fqn ? "singleton(#{fqn})" : nil
    end
  end
end
