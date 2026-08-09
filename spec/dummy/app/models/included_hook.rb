# frozen_string_literal: true

# `Module#included` is a plain RUBY hook, not a Rails one: `include X` calls
# `X.included(self)` with the includer as `base`. So `base.class_eval do ... end`
# inside it defines the block's methods on the INCLUDER, and a human reading this file
# knows exactly which class gets them.
#
# `ClassEvalExpander` (#197) declines it, correctly for what it knows: the receiver is
# a method PARAMETER, not a constant, so the call shape alone names no class. What
# makes it decidable is the hook's NAME — the hosts then come from the mixin graph
# (`MixinIndex#hosts_of`), not from the call.
#
# This is the plain-Ruby core of the `included do` problem: ActiveSupport::Concern is
# sugar over exactly this shape, so a fix here is a fix there, with no framework
# knowledge involved.
#
# A plain class on purpose — nothing here is Active Record, so the fixture needs no
# table.
class IncludedHook
  module Hookable
    def self.included(base)
      base.class_eval do
        def from_hook
          "hook"
        end

        # The load-bearing half, and the store-accessor shape: `super` can only resolve
        # if this def belongs to the HOST, whose ancestors have `IncludedHook::Slots`.
        # Attributed to `Hookable` it sits in a module that includes nothing, so there
        # is no super method at all and the return degrades to `untyped`.
        def slot
          super || "default"
        end
      end
    end
  end

  # A hook method named ANYTHING ELSE. Ruby invokes no hook here, so nothing static says
  # `foo_included` is ever called, let alone with an includer — what it would define
  # belongs to nobody. Here as the limit case, so a fix for the hook above cannot
  # quietly generalise to any `*_included` name.
  module Arbitrary
    def self.foo_included(base)
      base.class_eval do
        def from_arbitrary
          "arbitrary"
        end
      end
    end
  end

  # Two hosts for one hook block: the remaining ambiguity, not an oversight. One block,
  # two `base`s, and `super` inside it would resolve against a different chain in each —
  # the same disagreement felixefelip/steep#134 declines on rather than guess.
  module Shared
    def self.included(base)
      base.class_eval do
        def from_shared
          1
        end
      end
    end
  end

  # The `include` is the only thing that says who `base` is.
  include Slots
  include Hookable
end

# The call sites: the slot's writer is what gives `super` a type to return, and the
# reads are what a regression would surface as `NoMethod` rather than as a silently
# missing method.
class IncludedHookCaller
  def fill
    target = IncludedHook.new
    target.slot = "value"
    target.from_hook
  end

  # The success criterion, visible in a snapshot rather than in a diagnostic: `slot`
  # returns `super || "default"` over a `String?` slot, so this is `String` once the
  # hook's defs belong to the host. It reads `untyped` today because `super` resolves
  # against `Hookable`, which includes nothing.
  def read_slot
    IncludedHook.new.slot
  end

  def read_shared
    IncludedHookFirst.new.from_shared
  end
end
