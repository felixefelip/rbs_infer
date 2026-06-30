# frozen_string_literal: true

# felixefelip/rbs_infer#64: `track_event` é chamado *pelado* a partir de
# concerns IRMÃOS do host (`Widget::Publishable`/`Widget::Closeable`), que
# nunca nomeiam `Eventable` — com `String` num call-site e `Symbol` noutro.
# `action` deve então inferir `(String | Symbol)`, não apenas o primeiro tipo.
module Eventable
  extend ActiveSupport::Concern

  def track_event(action, **particulars)
    { action: action, particulars: particulars }
  end
end
