# A predicate that proves a SIBLING METHOD non-nil, paying for a dereference in
# another method.
#
#   def spiking?      = source.windowed? && wide_enough?
#   def wide_enough?  = source.window.size > 10
#
# `source.windowed?` is the whole reason `wide_enough?` is allowed to write
# `source.window.size`, and it is now what makes it type-check.
#
# The precondition machinery always did its half: `.steep_contracts.yml` gets
# `requires not_nil self.source.window` on `wide_enough?`, and
# `Contracts::Enforcement` enforces it once every visible call site satisfies
# it. What no call site could satisfy was the guard — so the requirement kept
# propagating up to `spiking?` and `detect` as `enforced: false`, and the body
# was checked with `source.window` still nilable.
#
# The guard now establishes: `Example67Source::AfterWindowed` restates
# `window` non-nil, `windowed?`'s `when_true.self` intersects it into `source`
# across the `&&`, and `wide_enough?`'s contract is discharged at its one call
# site. `spiking?` and `detect` carry no requirement at all any more.
#
# Read off fizzy: `Card::ActivitySpike::Detector#has_activity_spike?` guards with
# `card.entropic?` and `#recent_period` writes `card.entropy.auto_clean_period`.
class Example67
  attr_reader :source

  def initialize(source)
    @source = source
  end

  def detect
    if spiking?
      true
    else
      false
    end
  end

  private
    def spiking?
      source.windowed? && wide_enough?
    end

    def wide_enough?
      source.window.size > 10
    end
end
