# frozen_string_literal: true

# Sibling concern of Eventable in the Widget host; calls `track_event` bare
# with a `Symbol`, without ever naming `Eventable`.
module Widget::Publishable
  extend ActiveSupport::Concern

  def publish
    track_event(:published)
  end
end
