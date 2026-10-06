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
# which is then called even on nil. For `full_name` the checker answers it
# `false` — neither NilClass nor anything it reaches declares the method —
# so the condition is `!_.nil?`, and `_` narrows inside the `if` as under
# any other guard:
#
#   - `owner` may be nil: the method is the call or nothing, `String?`;
#   - `author` cannot be nil: the `if` always runs, `String`.
#
# Neither body is rejected, so neither infers a precondition, and `summary`
# owes them nothing.
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
