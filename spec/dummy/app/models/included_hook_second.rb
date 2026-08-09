# frozen_string_literal: true

# The second host, which is what makes the hook block ambiguous: one block, two `base`s.
class IncludedHookSecond
  include IncludedHook::Shared
end
