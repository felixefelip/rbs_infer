# frozen_string_literal: true

# felixefelip/rbs_infer#64: `track_event` is called *bare* from the host's
# SIBLING concerns (`Widget::Publishable`/`Widget::Closeable`), which never
# name `Eventable` — with `String` at one call-site and `Symbol` at another.
# `action` must then infer `(String | Symbol)`, not just the first type.
module Eventable
  extend ActiveSupport::Concern

  def track_event(action, **particulars)
    { action: action, particulars: particulars }
  end
end
