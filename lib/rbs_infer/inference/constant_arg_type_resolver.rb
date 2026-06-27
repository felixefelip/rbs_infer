module RbsInfer::Inference
  # Resolves a constant used as a method ARGUMENT to the RBS type of its
  # VALUE (felixefelip/rbs_infer#46).
  #
  # A bare constant name is only a valid type when it names a class/module —
  # `foo(User)` legitimately infers the param as `User`. But a value constant
  # (`CODE_LENGTH = 6`) is NOT a type: emitting `(CODE_LENGTH length)` is
  # invalid RBS (no such type exists), which Steep rejects. The fix is to
  # resolve such an argument to the type of the constant's value (`Integer`).
  #
  # Two tiers, precise first:
  #
  # 1. Same-file — Steep's `constant_types` over the referencing source. The
  #    common case (the constant defined in the file that calls the method);
  #    Steep types the RHS exactly.
  # 2. Cross-file — the RBS environment (`constant_type_from_env`): stdlib,
  #    gems, and previously-generated `sig/`. The defining file's RBS becomes
  #    available on a later stabilization pass, so this converges the same way
  #    method return types do across files.
  #
  # Class/module references resolve to nothing in either tier (a class isn't a
  # constant declaration), so the caller falls back to the bare name — the
  # `foo(User) -> User` convention is preserved.
  class ConstantArgTypeResolver
    # @param steep_bridge [SteepBridge, nil] oracle for the cross-file tier;
    #   nil disables it (the lightweight `.new`-call collectors in
    #   MethodTypeResolver have no Steep environment) and resolution degrades
    #   to the bare-name fallback, as before.
    # @param caller_constant_types [Hash{String=>String}] bare-name => type for
    #   constants DEFINED in the referencing source (`SteepBridge#constant_types`),
    #   the precise same-file tier. Empty is a valid "none known".
    def initialize(steep_bridge:, caller_constant_types: {})
      @steep_bridge = steep_bridge
      @caller_constant_types = caller_constant_types
    end

    # @param name [String, nil] the referenced constant path (`extract_constant_path`),
    #   e.g. "CODE_LENGTH" or "Foo::BAR"
    # @param namespace [String, nil] enclosing class/module FQN at the reference,
    #   for cross-file env lookup of a relative name
    # @return [String, nil] a VALID RBS type for the argument — the constant's
    #   value type (value constant) or its own name (class/module reference) —
    #   or nil when nothing resolved, in which case the caller emits `untyped`.
    #   Never returns an unresolved value-constant name: that's invalid RBS and
    #   poisons the shared env (felixefelip/rbs_infer#46).
    def resolve(name:, namespace: nil)
      return nil if name.nil?

      bare = name.sub(/\A::/, "")
      short = bare.split("::").last

      same_file = @caller_constant_types[short] || @caller_constant_types[bare]
      return same_file if same_file

      # No Steep env to classify against — preserve the legacy behavior of
      # keeping the bare name (the lightweight `.new`-call collectors).
      return name unless @steep_bridge

      @steep_bridge.constant_type_from_env(bare, namespace: namespace) ||
        (@steep_bridge.class_or_module?(bare, namespace: namespace) ? name : nil)
    end
  end
end
