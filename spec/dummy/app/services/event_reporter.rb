# frozen_string_literal: true

# Cross-class call-site of `EventTracker#track_event`, passing a `Symbol`.
# Combined with `EventTracker`'s own `String` call-site, this forces the
# inference `action: (String | Symbol)` (felixefelip/rbs_infer#64).
class EventReporter
  def report
    EventTracker.new.track_event(action: :reported)
  end
end
