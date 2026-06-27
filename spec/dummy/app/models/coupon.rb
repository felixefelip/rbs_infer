# Exercises constant-argument inference (#46): `Code.generate(CODE_LENGTH)`
# infers `length` as `Integer` (the constant's value type), not `CODE_LENGTH`.
class Coupon
  CODE_LENGTH = 8

  def self.make
    Code.generate(CODE_LENGTH)
  end
end
