# frozen_string_literal: true

# `send` reaches a PRIVATE method by name, and that is not a corner of the language: it is
# how MRI itself invokes the mixin hooks. `rb_mod_include` calls `append_features` and
# `included` with `rb_funcall`, which dispatches by name ignoring visibility, and both are
# private on `Module` — so the pseudo-code in `sig/generated/steep_ruby_runtime/module.rb`
# spells them `mod.send(:included, self)`, the only spelling that is true to the C.
#
# Nothing about a literal-symbol `send` is undecidable: the receiver's type is known and
# the method name is right there. Both repos read it as nothing today, and this fixture is
# where that shows:
#
# - rbs_infer does not see the call site. `SourceIndex` indexes the file under `send`, so
#   `files_calling("stamp")` is empty and `stamp`'s parameter is never typed — the same
#   class of miss as the bare `include` that rbs_infer#202 fixed, from the other end.
# - Steep checks nothing inside it. `send` returns `untyped`, so a wrong arity, a
#   misspelled name and a call on the result are all accepted in silence (measured: three
#   such lines, `No type error detected`).
#
# A plain class on purpose — nothing here is Active Record, so the fixture needs no table.
class SendDispatch
  def call
    "called"
  end

  private

  # The rbs_infer criterion: `value` has to come from the `send` call site in
  # `SendDispatchCaller#stamped`, exactly like any other cross-class argument. It reads
  # `untyped` today; it has to read `String`.
  def stamp(value)
    "stamped: #{value}"
  end

  # A private predicate, for the shape a real app sends to most: reaching past `private`
  # to ask something the public API does not expose.
  def stamped?(value)
    value.start_with?("stamped")
  end
end

# The call sites. Kept in their own class so they are cross-class calls, which is the path
# that types a parameter from its callers.
class SendDispatchCaller
  # The checker criterion: `send` with a literal symbol IS a call to that method, so this
  # is `String`. It reads `untyped` today, and neither a wrong arity nor a misspelled name
  # here would be reported at all.
  def stamped
    SendDispatch.new.send(:stamp, "post")
  end

  def stamped_predicate
    SendDispatch.new.send(:stamped?, "stamped: post")
  end

  # `public_send` respects visibility: reaching `stamp` with it raises `NoMethodError` at
  # runtime, so a fix must resolve it only for the PUBLIC method. Here as the boundary
  # between the two, over a method that is public.
  def called
    SendDispatch.new.public_send(:call)
  end

  # The limit case, and the reason a fix keys on the literal: the name is a value, so no
  # static analysis decides which method this is. It has to stay `untyped` — a fix that
  # types this one has guessed.
  def dynamic(name)
    SendDispatch.new.send(name)
  end
end
