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
# Since #239 the defs below are emitted NOWHERE. `ClassMemberCollector` no longer
# attributes a block's body to the module that lexically contains it — a block's `self`
# can be rebound, so the lexical owner was never the right answer — and nothing puts it
# on the host yet. What these snapshots pin today is therefore ABSENCE, and the Steep
# baseline records the `does not have method` errors that follow. That is the state #216
# has to end: not by putting the defs back on the module, which was the wrong owner all
# along, but by landing them on the host.
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
        # Today it belongs to nobody — the override is emitted nowhere — so `super`
        # is never typed and a read of `slot` reaches `Slots`' plain accessor instead.
        def slot
          super || "default"
        end
      end
    end
  end

  # The SAME shape, spelled with ActiveSupport::Concern's sugar. `included do ... end`
  # is `base.class_eval(&block)` with `base` the includer — Concern's `append_features`
  # runs it at include time — so `badge` below belongs to `IncludedHook` exactly as
  # `Hookable`'s `slot` does. The two sit here side by side because they are one
  # mechanism, and a fix for either that does not cover the other has missed that.
  #
  # This is the shape a real app writes: it is where fizzy's store-accessor overrides
  # live (`def indexed_by; (super || default_indexed_by).inquiry; end`).
  module Sugared
    extend ActiveSupport::Concern

    included do
      def from_sugar
        "sugar"
      end

      # The Concern-side criterion, over the other slot so it cannot collide with
      # `Hookable`'s. `super` only resolves if this def belongs to the HOST.
      def badge
        super || "sugared"
      end
    end
  end

  # The SAME sugar again, from a hand-rolled `included do` with no ActiveSupport in
  # sight (`IncludedHook::HomeMade`). Written identically to `Sugared` above, because the
  # call shape is what carries the meaning — so a fix that gated on
  # `extend ActiveSupport::Concern` would read fizzy's concerns and miss this one.
  module Homespun
    extend IncludedHook::HomeMade

    included do
      def from_homespun
        "homespun"
      end

      def stamp
        super || "homespun"
      end
    end
  end

  # A hook method named ANYTHING ELSE. Ruby invokes no hook here, so nothing static says
  # `foo_included` is ever called, let alone with an includer — what it would define
  # belongs to nobody. Here as the limit case, so a fix for the hook above cannot
  # quietly generalise to any `*_included` name.
  #
  # Since #239 that is also what the snapshot shows for the real hooks above, so absence
  # alone no longer tells the two apart. The criterion is what #216 changes: the hooks'
  # defs land on their hosts, and this one still lands nowhere.
  module Arbitrary
    def self.foo_included(base)
      base.class_eval do
        def from_arbitrary
          "arbitrary"
        end
      end
    end
  end

  # The `include`s are the only thing that says who `base` is, for both shapes.
  include Slots
  include Hookable
  include Sugared
  include Homespun
end

# The call sites: the slot's writer is what gives `super` a type to return, and the
# reads are what a regression would surface as `NoMethod` rather than as a silently
# missing method. Today `fill`'s `from_hook` and `read_shared`'s `from_shared` ARE that
# `NoMethod` — both sit in the Steep baseline, because since #239 neither method is
# declared anywhere.
class IncludedHookCaller
  # Writes both slots, which is what gives each `super` a type to return. Kept apart
  # from the reads below so those measure the ancestor chain rather than a local
  # narrowing of the value just written.
  def fill
    target = IncludedHook.new
    target.slot = "value"
    target.badge = "value"
    target.stamp = "value"
    target.from_hook
  end

  # The success criterion, visible in a snapshot rather than in a diagnostic: `slot`
  # returns `super || "default"` over a `String?` slot, so this is `String` once the
  # hook's defs belong to the host. It reads `String?` today because the override is
  # emitted nowhere: the read resolves to `Slots#slot`, and the `|| "default"` that
  # removes the nil is never seen.
  def read_slot
    IncludedHook.new.slot
  end

  # The same criterion for the sugared half, over a slot with a UNIQUE name: `tag` was
  # borrowed from the dummy's Tag model closely enough to pick up a type from
  # elsewhere, which made the two halves look asymmetric when they are not.
  # Both read `String?` today, for the same reason `read_slot` does, and both have to
  # become `String` — one fix, or the two shapes have been treated as two problems.
  def read_badge
    IncludedHook.new.badge
  end

  # And for the hand-rolled sugar. Three criteria, one fix.
  def read_stamp
    IncludedHook.new.stamp
  end

  # The two-hosts half, and the one place where the two sides say different things out
  # loud: this still infers `Integer` from the block's body, while the emitted RBS
  # declares no `from_shared` at all, so Steep reports the call as a missing method.
  # Both are pinned — the type here, the error in the baseline — so #216 has to close
  # the gap on both sides at once.
  def read_shared
    IncludedHookFirst.new.from_shared
  end
end
