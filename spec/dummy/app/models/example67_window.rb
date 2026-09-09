# The value half of the predicate-slot gap (see `example67.rb`).
#
# `.for` is a nilable factory: the bare `return` makes the answer
# `Example67Window?` no matter what is passed in, which is why the marker on the
# ARGUMENT is beside the point here — the nilability is the factory's own.
#
# Read off fizzy: `Card::Entropy.for`, whose `return unless card.last_active_at`
# does exactly this.
class Example67Window
  attr_reader :size

  def self.for(source)
    return unless source.enabled?

    Example67Window.new(source.window_size)
  end

  def initialize(size)
    @size = size
  end
end
