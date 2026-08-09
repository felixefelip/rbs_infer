# frozen_string_literal: true

# The mixin both hook blocks' `super` has to reach. Included by the HOST, not by the
# hookable modules — so it is only behind their methods if those methods belong to the
# host, which is the whole question.
#
# Two slots, both uniquely named, so the plain-Ruby hook and the ActiveSupport::Concern sugar can each
# override one on the SAME host, without colliding.
module IncludedHook::Slots
  def slot
    @slot
  end

  def slot=(value)
    @slot = value
  end

  def badge
    @badge
  end

  def badge=(value)
    @badge = value
  end

  def stamp
    @stamp
  end

  def stamp=(value)
    @stamp = value
  end
end
