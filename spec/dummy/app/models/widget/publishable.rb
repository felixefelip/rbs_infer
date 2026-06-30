# frozen_string_literal: true

# Concern irmão de Eventable no host Widget; chama `track_event` pelado com
# um `Symbol`, sem nunca nomear `Eventable`.
module Widget::Publishable
  extend ActiveSupport::Concern

  def publish
    track_event(:published)
  end
end
