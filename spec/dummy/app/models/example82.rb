# `delegate … allow_nil: true` (felixefelip/rbs_infer#393, item 3).
#
# ActiveSupport writes the body as
#
#   def owner_full_name(...)
#     _ = owner
#     if !_.nil? || nil.respond_to?(:full_name)
#       _.full_name(...)
#     end
#   end
#
# `nil.respond_to?(:full_name)` is there for a method nil itself has (`to_s`),
# which is then called even on nil. For `full_name` it is `false` — NilClass
# declares no such method — but the checker does not decide it, so it
# cannot narrow `_` inside the `if`:
#
#   - `owner` may be nil: the call is rejected (`NoMethod` on `User | nil`),
#     and the checker infers a precondition `not_nil self.owner` from it —
#     for a method whose whole point is accepting a nil owner. `summary`
#     below is flagged for not establishing it;
#   - `author` cannot be nil, and still reads as `(User | nil)` in the `if`
#     (#393, item 2): the same rejection, and a precondition every caller
#     meets, so nobody is flagged for it.
#
# Both come out `() -> untyped`.
#
# Deciding `nil.respond_to?(:full_name)` as `false` turns the condition into
# `!_.nil?`, which the checker narrows by itself: each method is the call or
# nil, `String?`, and neither needs anything of its callers.
#
# Nothing here states a type.
class Example82
  def owner = (User.new if rand > 0.5)
  def author = User.new

  delegate :full_name, to: :owner, prefix: true, allow_nil: true
  delegate :full_name, to: :author, prefix: true, allow_nil: true

  def self.summary
    card = Example82.new
    [card.owner_full_name, card.author_full_name]
  end
end
