# frozen_string_literal: true

# Two hosts for one hook block: the remaining ambiguity, not an oversight. One block, two
# `base`s, and `super` inside it would resolve against a different chain in each — the
# same disagreement felixefelip/steep#134 declines on rather than guess.
#
# Its own file, and that is load-bearing for a reason worth knowing: parameter inference
# keys usages by method NAME, so as a sibling of `Hookable` inside one target the
# argument inferred for `Hookable.included` was applied to this `included` too, and the
# checked-in signature read `singleton(IncludedHook)` — a class that includes neither.
module IncludedHook::Shared
  def self.included(base)
    base.class_eval do
      def from_shared
        1
      end
    end
  end
end
