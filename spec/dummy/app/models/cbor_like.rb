# Exercises value-position constant typing (felixefelip/rbs_infer#56): a value
# constant used as a keyword default and assigned to an ivar both resolve to the
# constant's VALUE type (Integer), never its bare name — which is invalid RBS and
# poisons the shared env. Mirrors the real ActionPack::WebAuthn::CborDecoder.
class CborLike
  MAX_DEPTH = 16

  def initialize(max_depth: MAX_DEPTH)
    @max_depth = max_depth
    @limit = MAX_DEPTH
    @depth = 0
  end

  # Reads the ivars so they're emitted; an array literal keeps the return type
  # deterministic (no Steep-convergence dependence in the snapshot).
  def levels
    [@max_depth, @limit, @depth]
  end
end
