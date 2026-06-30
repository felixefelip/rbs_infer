# frozen_string_literal: true

# Reproduz felixefelip/rbs_infer#64: `track_event` é chamado com `String` em
# alguns call-sites (aqui, intra-classe) e com `Symbol` em outros (ver
# `EventReporter`), então `action` deve inferir `(String | Symbol)` — não
# apenas o primeiro tipo visto.
class EventTracker
  def track_event(action:)
    { action: action }
  end

  # Call-site intra-classe com `String` literal.
  def track_created
    track_event(action: "created")
  end
end
