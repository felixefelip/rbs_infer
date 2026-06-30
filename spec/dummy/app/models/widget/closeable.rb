# frozen_string_literal: true

# Another sibling concern; also calls `track_event` bare with a `Symbol`.
module Widget::Closeable
  extend ActiveSupport::Concern

  def close
    track_event(:closed)
  end

  # felixefelip/rbs_infer#63: bare call to a method `Publishable` created via
  # `alias_method`. Resolves only if that alias reached `Widget`'s RBS — here
  # self is `(Widget & Widget::Closeable)`, the issue's failing shape.
  def reopen
    track_event(:reopened) if was_just_published?
  end
end
