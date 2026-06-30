# frozen_string_literal: true

# Host plain-Ruby (não-AR) que mixa o concern Eventable e os concerns irmãos
# que o chamam pelado. Espelha o padrão do Fizzy (Card include Eventable,
# Statuses, Assignable, ...).
class Widget
  include Eventable
  include Widget::Publishable
  include Widget::Closeable

  # Host call-site, com `String`.
  def rename
    track_event("renamed")
  end
end
