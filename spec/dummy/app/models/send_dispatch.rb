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
# The caller below has two halves. The first is inference that is missing: a parameter and
# a return type that read `untyped` and have to read a type. The second is code that has to
# start FAILING — `public_send` reaching a private method, a name that resolves nowhere, a
# wrong arity — accepted in silence today, and each one a runtime error. Both halves are
# invisible in the snapshot for the same reason (`send` is `untyped`), which is why the
# second half is spelled out in comments here and belongs in `steep_baseline.txt` once
# resolved.
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

  # The same thing, spelled the other three ways Ruby spells it. A fix that fires only on
  # `send` with a `:symbol` covers the fixture above and misses these — all four are one
  # dispatch, and `__send__` is the one a defensive library uses precisely because `send`
  # can be overridden.
  def underscored
    SendDispatch.new.__send__(:stamp, "post")
  end

  def string_named
    SendDispatch.new.send("stamp", "post")
  end

  # ─── The half that has to become an ERROR ────────────────────────────────────────
  #
  # Everything below is accepted in silence today, and each line is a runtime failure —
  # which is the whole argument for resolving a literal-name `send`. They are deliberately
  # wrong, like the intentional errors in `example7.rb`, and after a fix each one belongs
  # in `sig/generated/steep_baseline.txt` rather than in the source.

  # `public_send` respects visibility, so this is a `NoMethodError` at runtime even though
  # `stamp` exists. A different error from "no such method" and worth a different message:
  # the name resolves, the call does not.
  def stamped_publicly
    SendDispatch.new.public_send(:stamp, "post")
  end

  # No method by this name, at any visibility. Measured: Steep already reports the plain
  # spelling of this (`Ruby::NoMethod`) even for a class that declares `method_missing`,
  # so resolving `send` adds no new judgment — it removes an exception.
  def missing_name
    SendDispatch.new.send(:no_such_method_anywhere)
  end

  # Right name, wrong number of arguments: `ArgumentError` at runtime.
  def wrong_arity
    SendDispatch.new.send(:stamp, "a", "b", "c")
  end

  # And the case that must NOT error: a splat of unknown length says nothing about how
  # many arguments arrive, so a fix resolves the name and the return type and stays quiet
  # about the arguments.
  def splatted(*args)
    SendDispatch.new.send(:stamp, *args)
  end

  # The shape that will make the most noise in a real codebase, and the reason the
  # diagnostic wants an ID of its own to tune: a `respond_to?` guard does not put the
  # method in the RBS, so this errors even though the code is careful. Silent today.
  def guarded
    target = SendDispatch.new
    target.send(:no_such_method_anywhere) if target.respond_to?(:no_such_method_anywhere)
  end
end
