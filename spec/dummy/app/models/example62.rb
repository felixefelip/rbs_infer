# frozen_string_literal: true

# A DSL that DEFERS its stored block, written by hand with no ActiveSupport in
# sight (felixefelip/rbs_infer#300).
#
# `IncludedHook::HomeMade` is the other half of this pair: same `included do`
# spelling, and its `class_eval` runs on whoever includes it, so its defs belong
# to that module. This one is the opposite — `append_features` registers the
# module on the target when the target is itself one of ours, and the block runs
# only when a real class arrives. `Middle` is a WAYPOINT, and `Example62` is
# where `label` lands. `ActiveSupport::Concern` is exactly this shape; the point
# of writing it out is that nothing here is Rails.
#
# The criterion is `super`, as it is in `included_hook.rb`: it resolves only if
# the def belongs to `Example62`, whose ancestors carry `Slots`. Attributed to
# `Middle` instead, there is no `label` behind it and the read below errors —
# which is what the Steep baseline records today.
#
# The registration is spelled `push(self)`. `<<` would say the same thing and is
# what activesupport happens to write; the two are one operation, and a pass that
# reads only the second is matching a spelling rather than the meaning. That is
# the gap #300 closes: `Collector#defers_onto_target?` searches for `<< self`, so
# this file resolves as if nothing were deferred.
class Example62
  module Slots
    def label
      nil
    end
  end

  # The DSL. `append_features` is Ruby's own hook, so `include` reaches it
  # through the runtime sidecar without anything naming this module.
  module Deferring
    # `Array.new` rather than `[]`, for the reason the transcribed
    # `ActiveSupport::Concern` gives for the same line: an empty literal has no
    # element to read a type off, and a warning about it would be noise in a
    # fixture that is about something else.
    def self.extended(base)
      base.instance_variable_set(:@deferred, Array.new)
    end

    def keep(&block)
      @kept = block
    end

    def append_features(base)
      if base.instance_variable_defined?(:@deferred)
        # The target is another module of ours: hand it SELF and stop. The block
        # has not run, and this target is not where it lands.
        base.instance_variable_get(:@deferred).push(self)
      else
        # A real class: replay what was handed over, then our own block.
        @deferred.each { |mod| base.include(mod) }
        super
        base.class_eval(&@kept) if @kept
      end
    end
  end

  module Shared
    extend Deferring

    keep do
      def label
        super || "shared"
      end
    end
  end

  # The waypoint. It extends the DSL, so it carries `@deferred` and `Shared`
  # registers itself here instead of running.
  module Middle
    extend Deferring

    include Shared
  end

  include Slots
  include Middle
end

# The read that makes the landing visible: `String` when the def belongs to
# `Example62` (its `super` reaches `Slots#label`), and an error when it is
# attributed to `Middle`.
class Example62Caller
  def read_label
    Example62.new.label
  end
end
