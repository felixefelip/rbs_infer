# Plain Ruby class (not ActiveRecord) exercising class-constant inference
# (felixefelip/rbs_infer#37): scalar literals, frozen literals, and the
# frozen collection-builder idiom whose block returns `new(...)`.
class Palette
  MAX = 8
  DEFAULT_NAME = "Blue"
  WEIGHTS = [1, 2, 3].freeze

  def initialize(name, value)
    @name = name
    @value = value
  end

  # Return is a bare value constant (#46): the type is the constant's VALUE
  # type (`Integer`), resolved by Steep — not the bare name `MAX`, which is
  # invalid RBS.
  def max_weight
    MAX
  end

  COLORS = {
    "Blue" => "var(--color-1)",
    "Gray" => "var(--color-2)"
  }.collect { |name, value| new(name, value) }.freeze
end
