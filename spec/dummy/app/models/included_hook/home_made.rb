# frozen_string_literal: true

# A hand-rolled `included do`, with no ActiveSupport anywhere. The whole mechanism is
# right here: without an argument the call is the DSL and stores the block; with one it
# is Ruby's own `included` hook, and replays the block on the includer — the same trick
# `ActiveSupport::Concern#included` plays, in six lines.
#
# It exists so a fix for `included do` cannot gate on `extend ActiveSupport::Concern`.
# The call SHAPE is identical either way, and it is the shape that carries the meaning:
# a receiverless `included` with a block, in a module, replayed on whoever includes it.
# Keying on the framework would read fizzy's concerns and miss this one, though a human
# reading either knows the same thing.
#
# Verified to behave as ActiveSupport's does: with `Host.include Homespun`, the def
# lands on `Host` (`Host.instance_method(:stamp).owner == Host`) and its `super` reaches
# the mixin behind it.
module IncludedHook::HomeMade
  # The explicit `nil` is not ceremony: without it the two branches return the stored
  # block and `class_eval`'s value, and the inferred return type came out as a non-nil
  # Proc while the body can yield nil — a `SetterBodyTypeMismatch`-style error about this
  # helper, in a fixture that is about something else entirely. Ruby never uses the
  # hook's return value, so saying so removes the noise without changing behaviour.
  def included(base = nil, &block)
    if base.nil?
      @included_block = block
    else
      base.class_eval(&@included_block) if @included_block
    end

    nil
  end
end
