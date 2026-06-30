# frozen_string_literal: true

# Another sibling concern; also calls `track_event` bare with a `Symbol`.
module Widget::Closeable
  extend ActiveSupport::Concern

  def close
    track_event(:closed)
  end
end
