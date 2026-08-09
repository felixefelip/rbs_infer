# frozen_string_literal: true

# The mixin the `class_eval` block's `super` has to reach. Nothing here is special
# — the point of the fixture is entirely on the `class_eval` side, where the `def`
# is written outside any `class`/`module` body and so has no lexical owner at all.
module EvalReopen::Slots
  def slot
    @slot
  end

  def slot=(value)
    @slot = value
  end
end
