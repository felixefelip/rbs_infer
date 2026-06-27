module RbsInfer::Inference
  # Resolves a constant used as a method ARGUMENT to its VALUE's RBS type
  # (felixefelip/rbs_infer#46). A bare name is a valid type only for a
  # class/module (`foo(User)` → `User`); a value constant (`CODE_LENGTH = 6`)
  # is not, so it must resolve to its value's type (`Integer`).
  #
  # Two tiers: the referencing source's own constants (`constant_types`,
  # precise), then the RBS environment (`constant_type_from_env`: stdlib,
  # gems, generated `sig/`) for cross-file constants. A class/module isn't a
  # constant declaration, so it resolves to nothing and keeps its name;
  # anything else unresolved → nil → caller emits `untyped`.
  class ConstantArgTypeResolver
    # caller_constant_types: bare-name => type for constants defined in the
    # referencing source. steep_bridge nil disables the cross-file tier (the
    # Steep-less `.new`-call collectors) → bare-name fallback, as before.
    def initialize(steep_bridge:, caller_constant_types: {})
      @steep_bridge = steep_bridge
      @caller_constant_types = caller_constant_types
    end

    # Returns a valid RBS type (value type, or the name for a class/module),
    # or nil when nothing resolved — never an unresolved value-constant name,
    # which is invalid RBS and poisons the shared env.
    def resolve(name:, namespace: nil)
      return nil if name.nil?

      bare = name.sub(/\A::/, "")
      short = bare.split("::").last

      same_file = @caller_constant_types[short] || @caller_constant_types[bare]
      return same_file if same_file

      # No env to classify against → keep the bare name (legacy behavior).
      return name unless @steep_bridge

      @steep_bridge.constant_type_from_env(bare, namespace: namespace) ||
        (@steep_bridge.class_or_module?(bare, namespace: namespace) ? name : nil)
    end
  end
end
