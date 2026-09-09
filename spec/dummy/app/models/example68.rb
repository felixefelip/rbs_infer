# A `==` against a non-nil value proves its RECEIVER non-nil, and through a `&.`
# chain that reaches the root:
#
#   def matched?
#     latest&.label&.to_s == "opened" && latest.stamp > 0
#   end
#
# `nil == "opened"` is false, so a truthy comparison means the left side was not
# nil; and `x&.m` answers nil whenever `x` is, so a non-nil answer means `x` was
# not nil either. Both steps hold for any receiver — the nil component of a union
# dispatches `==` to identity, and `&.` is defined by that very short-circuit.
#
# The five methods below are the same guard written five ways. They separated two
# independent gaps, and both are closed:
#
#   1  latest && latest.stamp
#   2  latest&.label && latest.stamp                      <- (B)
#   2b entry&.label && entry.stamp
#   3  latest&.label&.to_s == "opened" && latest.stamp    <- (A) and (B)
#   4  entry&.label&.to_s == "opened" && entry.stamp      <- (A)
#
# (A) The comparison was never the problem: Steep types `==` as
#     `Logic::ReceiverIsArg` and already partitions the receiver's union against
#     the literal, dropping `nil` from the truthy side. What it had nowhere to put
#     that answer was a `:csend` node — `refine_node_type` had no branch for one,
#     so the fact stopped at the chain and never reached `latest`. It now walks
#     down: a truthy type that cannot be nil proves the `&.`'s receiver non-nil,
#     one link per `&.`, and only on the truthy side (a nil answer is ambiguous
#     between "receiver was nil" and "the call answered nil").
#
# (B) a `&.` narrowed its receiver only when that receiver was a local. `:csend`
#     synthesis joins the env back to its pre-call state because the CALL may not
#     have happened — but the RECEIVER always ran, and `TypeEnv#join` keeps a pure
#     call only when both sides hold it, so the registration made while
#     synthesizing the receiver was dropped. It is now carried across the join,
#     which composes down a chain: each `&.` carries its own receiver.
#
# Read off fizzy: `Card::ActivitySpike::Detector#card_was_just?`, where
# `last_event&.action&.to_s == "card_#{action}" && last_event.created_at` answered
# `Type ((::Event & ::Event::Validated) | nil) does not have method created_at`.
#
# The two markers in this class's RBS are the other half of the same reading, and
# they are about CALLERS: a truthy `labelled_and_stamped?` (or
# `matched_and_stamped?`) means `latest` is there.
class Example68
  def entries
    [Example68Entry.new("opened", 1), Example68Entry.new(nil, 0)]
  end

  # Nilable the way `card.events.order(:created_at).last` is: the collection may
  # be empty. `label` is nilable on its own account, so the chain is nilable
  # twice over and a non-nil answer settles both.
  def latest
    return nil if entries.empty?

    entries.last
  end

  # 1. The plain guard. Nothing between the receiver and the `&&`.
  def present_and_stamped?
    latest && latest.stamp > 0
  end

  # 2. A `&.` guard. The interpreter narrows a csend's receiver on the truthy
  #    branch, so this is the shape that already works.
  def labelled_and_stamped?
    latest&.label && latest.stamp > 0
  end

  # 2b. The same `&.` guard through a local. A local survives the join the csend
  #     synthesis performs; a pure-call registration does not.
  def labelled_via_local?
    entry = latest
    entry&.label && entry.stamp > 0
  end

  # 3. The fizzy shape: the comparison sits between the chain and the `&&`.
  def matched_and_stamped?
    latest&.label&.to_s == "opened" && latest.stamp > 0
  end

  # 4. The same through a local, to pin that the gap is about the `==` and not
  #    about the slot being a method call.
  def matched_via_local?
    entry = latest
    entry&.label&.to_s == "opened" && entry.stamp > 0
  end
end
