# The value the chain walks through. `label` is nilable the way an enum column
# is, so `entry&.label` is `String?` for two independent reasons — the entry may
# be absent AND the label may be unset — which is what makes the chain worth
# reading rather than guessing at.
class Example68Entry
  attr_reader :label, :stamp

  def initialize(label, stamp)
    @label = label
    @stamp = stamp
  end

  # An `untyped` link, with no diagnostic of its own — `Object#public_send` is
  # declared `-> untyped`. fizzy gets one the same way without meaning to:
  # `Event#action` is `def action; super.inquiry; end`, `inquiry` resolves
  # nowhere, and rbs_infer writes `() -> untyped`.
  def marker
    method(:label).call
  end
end
