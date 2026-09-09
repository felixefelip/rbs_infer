# A predicate that proves a SIBLING METHOD non-nil establishes nothing, so a
# guard in one method cannot pay for a dereference in another.
#
#   def spiking?      = source.windowed? && wide_enough?
#   def wide_enough?  = source.window.size > 10
#
# `source.windowed?` is the whole reason `wide_enough?` is allowed to write
# `source.window.size`, and Steep answers `Type (::Example67Window | nil) does
# not have method size`.
#
# The precondition machinery already does its half: `.steep_contracts.yml` gets
# `requires not_nil self.source.window` on `wide_enough?` and propagates it to
# `spiking?` and `detect`, all `enforced: false`. It stops exactly where the
# guard sits — `Contracts::Enforcement` enforces a contract only when every
# visible call site satisfies it, and the call site of `wide_enough?` is behind
# a `source.windowed?` that narrows nothing.
#
# The predicate-marker pipeline covers the same shape over an IVAR
# (`def confirmed?; !@name.nil?; end` → `AfterConfirmed` with
# `attr_reader name: ::String`, emitted by `PredicateMarkerSynthesizer` from
# `when_true.ivars`). Over a method it produces nothing, for two reasons stated
# in `example67_source.rb`. The consumer side is already there:
# `LogicTypeInterpreter#apply_postconditions` refines a pure-send receiver
# through `refine_node_type`, so a `when_true.self:
# "::Example67Source & ::Example67Source::AfterWindowed"` carrying
# `def window: () -> Example67Window` would narrow `source` across the `&&` with
# no new consumer.
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
