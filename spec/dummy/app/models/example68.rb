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
# The five methods below are the same guard written five ways, and the baseline
# records which of them Steep follows. Two gaps fall out, and they are
# independent:
#
#   1  latest && latest.stamp             ok
#   2  latest&.label && latest.stamp      NO  <- (B)
#   2b entry&.label && entry.stamp        ok
#   3  latest&.label&.to_s == "opened" && latest.stamp   NO  <- (A) and (B)
#   4  entry&.label&.to_s == "opened" && entry.stamp     NO  <- (A)
#
# (A) `==` is a wall. `LogicTypeInterpreter#eval` never looks inside a comparison
#     to ask what a truthy answer says about its receiver, so 4 fails even with a
#     local — the slot being a method call has nothing to do with it.
#
# (B) a `&.` narrows its receiver only when that receiver is a local. `:csend`
#     synthesis joins the env back to its pre-call state (`type_construction.rb`,
#     `when :csend`) because the call may not have happened, and `TypeEnv#join`
#     keeps only the pure calls present in BOTH envs — so the receiver's own
#     registration, made while synthesizing it, is dropped before the interpreter
#     can refine it. A local survives the join; a pure call does not. That is 2
#     versus 2b.
#
# fizzy's line needs both: its root is a method call, and the comparison sits
# between that root and the `&&`. `Card::ActivitySpike::Detector#card_was_just?`
# writes `last_event&.action&.to_s == "card_#{action}" && last_event.created_at`
# and answers `Type ((::Event & ::Event::Validated) | nil) does not have method
# created_at`.
#
# One thing already works and is worth not mistaking for the fix: the marker
# `AfterLabelledAndStamped` in this class's RBS. `Postconditions::Inferrer` seeds
# its own synthetic env with the body's pure calls, so it proves what the checker
# cannot — that a truthy `labelled_and_stamped?` means `latest` is there. True,
# and about this method's CALLERS; the body still cannot read `latest.stamp`.
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
