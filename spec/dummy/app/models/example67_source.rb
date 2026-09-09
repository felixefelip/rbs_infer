# The guarded half. `window` is nilable and `windowed?` is the predicate that
# decides it — the pair a human reads as "past `windowed?`, `window` is there".
#
# Neither is an ivar, and this class declares no ivar at all. Both facts matter
# to `Steep::Postconditions::Inferrer`: `build_env_for_class` returns nil when a
# class has no declared ivar, so the predicate path never starts; and
# `collect_when_true_nonnil_refinements` reads only
# `truthy_result.env.instance_variable_types`, so a method slot would be dropped
# even if it did.
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
  # visible caller is never enforced, so without this the chain below could not
  # be quitted even once the predicate does prove something.
  def detect_spikes
    Example67.new(self).detect
  end
end
