# frozen_string_literal: true

# Call-site cross-class de `EventTracker#track_event`, passando um `Symbol`.
# Combinado com o call-site `String` de `EventTracker`, força a inferência
# `action: (String | Symbol)` (felixefelip/rbs_infer#64).
class EventReporter
  def report
    EventTracker.new.track_event(action: :reported)
  end
end
