# Exercises constant-argument inference (felixefelip/rbs_infer#46): a value
# constant passed to a submodule method resolves to its VALUE type
# (`CODE_LENGTH = 8` → `Integer`), never the bare constant name.
class Coupon
  CODE_LENGTH = 8

  def self.make
    Code.generate(CODE_LENGTH)
  end
end
