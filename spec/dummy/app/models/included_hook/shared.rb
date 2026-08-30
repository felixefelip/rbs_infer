# frozen_string_literal: true

# Two hosts for one hook block. The block itself is no ambiguity — it runs on both, the
# RBS declares its `def` on both (#263), and the sidecar names both in one `@implements`
# (#289). What stays open is `super` INSIDE such a block: two `base`s, and it would
# resolve against a different chain in each — the same disagreement felixefelip/steep#134
# declines on rather than guess.
#
# Its own file, and that USED to be load-bearing: parameter inference keyed usages by
# method NAME, so as a sibling of `Hookable` inside one target the argument inferred for
# `Hookable.included` was applied to this `included` too, and the checked-in signature
# read `singleton(IncludedHook)` — a class that includes neither. Fixed in
# felixefelip/rbs_infer#215: the table is keyed by the method's identity (owner, kind,
# name), and `Example23` pins the two-homonyms-in-one-target case. The separation here
# is now only about the two-hosts ambiguity above.
module IncludedHook::Shared
  def self.included(base)
    base.class_eval do
      def from_shared
        1
      end
    end
  end
end
