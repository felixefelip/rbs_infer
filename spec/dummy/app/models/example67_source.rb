# The guarded half. `window` is nilable and `windowed?` is the predicate that
# decides it — the pair a human reads as "past `windowed?`, `window` is there",
# and the pair the `AfterWindowed` marker in this file's RBS now states.
#
# Neither is an ivar, and this class declares no ivar at all. Both facts used to
# stop `Steep::Postconditions::Inferrer` cold: `build_env_for_class` turned away
# a class with no declared ivar before the interpreter was asked, and
# `collect_when_true_nonnil_refinements` read only
# `truthy_result.env.instance_variable_types`, so a method slot was dropped even
# when the env existed.
#
# Read off fizzy: `Card::Entropic#entropy` / `#entropic?`.
class Example67Source
  def enabled?
    window_size.positive?
  end

  def window_size
    30
  end

  def window
    Example67Window.for(self)
  end

  def windowed?
    window.present?
  end

  # The static call site the contract enforcement needs: a method with no
  # visible caller is never enforced, so without this the chain in `example67.rb`
  # could not be quitted however well the predicate proves its half.
  def detect_spikes
    Example67.new(self).detect
  end
end
