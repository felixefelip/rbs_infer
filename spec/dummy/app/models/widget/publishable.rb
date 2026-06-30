# frozen_string_literal: true

# Sibling concern of Eventable in the Widget host; calls `track_event` bare
# with a `Symbol`, without ever naming `Eventable`.
module Widget::Publishable
  extend ActiveSupport::Concern

  def publish
    track_event(:published)
  end

  def published?
    true
  end

  # felixefelip/rbs_infer#63: a method created via `alias_method` (and the
  # `alias` keyword) must reach the host's RBS, so a *sibling* concern can
  # call it bare where self is `(Widget & Widget::Closeable)`.
  alias_method :was_just_published?, :published?
  alias just_published? published?
end
