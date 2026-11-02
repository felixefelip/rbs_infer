# A generic class built with `new` and no arguments. RBS needs one per
# parameter, so the ivar is `Set[untyped]`: a bare `Set` is an error in the
# signature file, and that takes down the whole environment.
class Example112
  attr_reader :tags

  def initialize
    @tags = Set.new
  end
end
