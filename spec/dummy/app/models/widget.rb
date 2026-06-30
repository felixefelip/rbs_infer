# frozen_string_literal: true

# Plain-Ruby (non-AR) host that mixes in the Eventable concern and the sibling
# concerns that call it bare. Mirrors the Fizzy pattern (Card includes
# Eventable, Statuses, Assignable, ...).
class Widget
  include Eventable
  include Widget::Publishable
  include Widget::Closeable

  # Host call-site, with `String`.
  def rename
    track_event("renamed")
  end
end
