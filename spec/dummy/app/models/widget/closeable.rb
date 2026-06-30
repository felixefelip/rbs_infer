# frozen_string_literal: true

# Outro concern irmão; também chama `track_event` pelado com um `Symbol`.
module Widget::Closeable
  extend ActiveSupport::Concern

  def close
    track_event(:closed)
  end
end
