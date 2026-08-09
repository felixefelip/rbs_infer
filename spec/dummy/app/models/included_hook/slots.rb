# frozen_string_literal: true

# The mixin the hook block's `super` has to reach. Included by the HOST, not by the
# hookable module — so it is only behind the hook's methods if those methods belong to
# the host, which is the whole question.
module IncludedHook::Slots
  def slot
    @slot
  end

  def slot=(value)
    @slot = value
  end
end
