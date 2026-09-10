# A `==` against a non-nil value proves its RECEIVER non-nil, and through a `&.`
# chain that reaches the root:
#
#   def matched?(suffix)
#     latest&.marker&.to_s == "opened_#{suffix}" && latest.stamp > 0
#   end
#
# `nil == "opened_x"` is false, so a truthy comparison means the left side was not
# nil; and `x&.m` answers nil whenever `x` is, so a non-nil answer means `x` was
# not nil either. Both steps hold for any receiver — the nil member of a union
# dispatches `==` to identity, and `&.` is defined by that very short-circuit.
#
# The methods below are one guard written many ways. Each writing was a separate
# gap, and all are closed:
#
#   1  latest && latest.stamp
#   2  latest&.label && latest.stamp                             <- (B)
#   2b entry&.label && entry.stamp
#   3  latest&.label&.to_s == "opened" && latest.stamp           <- (A) and (B)
#   4  entry&.label&.to_s == "opened" && entry.stamp             <- (A)
#   5  latest&.label&.to_s == "opened_#{suffix}" && …            <- (C)
#   6  latest&.marker&.to_s == "opened_#{suffix}" && …           <- (C), untyped link
#   7  last_post&.title&.to_s == "draft_#{suffix}" && …          <- (C), record root
#
# (A) The comparison was never the problem for a LITERAL: Steep types `==` as
#     `Logic::ReceiverIsArg` and already partitions the receiver's union against
#     the literal, dropping `nil` from the truthy side. What it had nowhere to put
#     that answer was a `:csend` node — `refine_node_type` had no branch for one,
#     so the fact stopped at the chain and never reached `latest`. It now walks
#     down, one link per `&.`, and only on the truthy side (a nil answer is
#     ambiguous between "receiver was nil" and "the call answered nil").
#
# (B) a `&.` narrowed its receiver only when that receiver was a local. `:csend`
#     synthesis joins the env back to its pre-call state because the CALL may not
#     have happened — but the RECEIVER always ran, and `TypeEnv#join` keeps a pure
#     call only when both sides hold it, so the registration made while
#     synthesizing the receiver was dropped. It is now carried across the join.
#
# (C) and none of that fires on the shape fizzy actually writes.
#     `literal_var_type_case_select` switches on the argument NODE's type and
#     knows `:nil`, `:true`, `:false`, `:int`, `:str`, `:sym` — an interpolation
#     is a `:dstr` and answers nothing, so the whole `ReceiverIsArg` branch
#     declines. Worse, one unresolved link anywhere makes the comparison itself
#     `untyped`, and `guess_type_from_method` knows `is_a?`, `nil?`, `!` and
#     `===`, not `==`, so there is no logic type to dispatch on at all.
#
#     Nil-ness needs neither. `a == b` dispatches on `a`; a nil `a` resolves `==`
#     to identity; `b`'s type says it is never nil. So the fact is about `a`'s
#     VALUE, and it travels a chain whose own types say nothing — an `untyped`
#     link is walked THROUGH, and only links with a nilable type are refined.
#
# 5, 6 and 7 are the three things fizzy has and 1-4 did not: an interpolated
# right-hand side, an `untyped` link in the middle (`Event#action` is
# `def action; super.inquiry; end`), and a root whose non-nil member is an
# intersection (`(Event & Event::Validated)?`).
#
# Read off fizzy: `Card::ActivitySpike::Detector#card_was_just?`, where
# `last_event&.action&.to_s == "card_#{action}" && last_event.created_at` answered
# `Type ((::Event & ::Event::Validated) | nil) does not have method created_at`.
#
# The markers in this class's RBS are the other half of the same reading, and they
# are about CALLERS: a truthy `matched_untyped_link?` means `latest` is there.
class Example68
  def store
    Example68Store.new
  end

  # A ONE-LINE forwarder, like fizzy's
  # `def last_event; card.events.order(:created_at).last; end` — which is what
  # the delegation registry reads as a delegate.
  def latest
    store.newest
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

  # 5. fizzy's ACTUAL right-hand side: an interpolation, not a literal.
  #    `literal_var_type_case_select` switches on the argument NODE's type and
  #    knows `:nil`, `:true`, `:false`, `:int`, `:str`, `:sym`. A `:dstr` matches
  #    none of them, so it answers nothing and the whole `ReceiverIsArg` branch
  #    declines — there is no literal to partition the union against, and nil is
  #    never dropped. Nothing about the chain; 3 and 4 above hide it by using a
  #    bare `"opened"`.
  def matched_interpolated?(suffix)
    latest&.label&.to_s == "opened_#{suffix}" && latest.stamp > 0
  end

  # 6. fizzy's shape entire: an interpolation on the right AND an `untyped` link
  #    in the chain. `latest&.marker` is `untyped`, so the whole comparison is —
  #    and `guess_type_from_method` knows `is_a?`, `nil?`, `!` and `===`, not
  #    `==`, so there is no logic type to dispatch on either.
  def matched_untyped_link?(suffix)
    latest&.marker&.to_s == "opened_#{suffix}" && latest.stamp > 0
  end

  # 7. The last structural difference from fizzy: a root whose non-nil member is
  #    an INTERSECTION, not a plain class. `last_post` is
  #    `(Post & Post::Validated)?` exactly as fizzy's `last_event` is
  #    `(Event & Event::Validated)?`.
  def last_post
    Post.order(:created_at).last
  end

  def matched_on_a_record?(suffix)
    last_post&.title&.to_s == "draft_#{suffix}" && last_post.created_at > Time.current
  end
end
