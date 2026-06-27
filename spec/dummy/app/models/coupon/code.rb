module Coupon::Code
  class << self
    def generate(length)
      SecureRandom.hex(length)
    end
  end
end
