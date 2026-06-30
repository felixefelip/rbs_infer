# frozen_string_literal: true

# Reproduces felixefelip/rbs_infer#64: `track_event` is called with `String` at
# some call-sites (here, intra-class) and with `Symbol` at others (see
# `EventReporter`), so `action` must infer `(String | Symbol)` — not just the
# first type seen.
class EventTracker
  def track_event(action:)
    { action: action }
  end

  # Intra-class call-site with a `String` literal.
  def track_created
    track_event(action: "created")
  end
end
