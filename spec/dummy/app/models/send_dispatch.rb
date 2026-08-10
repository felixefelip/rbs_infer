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
# - **Steep resolves it now** (felixefelip/steep#137). A literal-name `send` is read as a
#   call to that method, so the arguments are checked and the return type is taken. That is
#   why the snapshot below reads `String` where it used to read `untyped`, with no rbs_infer
#   change at all: `SteepBridge` uses the checker as the return-type oracle, so the win
#   arrives through the existing pipeline.
# - **rbs_infer reads the call site now** (rbs_infer#205). `SourceIndex` indexed the file
#   under `send` — a name no caller asks about — so `files_calling("stamp")` was empty and
#   the file was never opened as a caller; and even opened, the collector saw a call to
#   `send` whose first argument happened to be a symbol. Both halves are closed, and
#   `stamp`'s parameter is typed from the `send` below like any other cross-class argument.
#   Same class of miss as the bare `include` that rbs_infer#202 fixed, from the other end.
#
# The caller below has two halves. The first is inference: return types that now read a
# type, and one parameter (`SendDispatch#stamp`'s `value`) that still reads `untyped`. The
# second is code that has to FAIL — `public_send` reaching a private method, a name that
# resolves nowhere, a wrong arity — each one a runtime error, silent before #137 and
# reported now. Those live in `sig/generated/steep_baseline.txt`, which is where a
# deliberate error belongs once the checker can see it.
#
# A plain class on purpose — nothing here is Active Record, so the fixture needs no table.
class SendDispatch
  def call
    "called"
  end

  private

  # The rbs_infer criterion, now MET (#205): `value` comes from the `send` call site in
  # `SendDispatchCaller#stamped`, exactly like any other cross-class argument. Steep
  # resolving the call (felixefelip/steep#137) did nothing for this one — the checker READS
  # a call site, `SourceIndex` had to FIND it, and it was indexing the file under `send`.
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
  # The checker criterion, now MET: `send` with a literal symbol IS a call to that method,
  # so this is `String` — in the snapshot, without rbs_infer knowing anything about `send`,
  # because `SteepBridge` asks the checker for the return type.
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

  # ─── The half that had to become an ERROR, and did ───────────────────────────────
  #
  # Every line below was accepted in silence before felixefelip/steep#137, and each one is a
  # runtime failure — which was the whole argument for resolving a literal-name `send`. They
  # are deliberately wrong, like the intentional errors in `example7.rb`, so each now sits in
  # `spec/expectations/steep_baseline.txt`. If one of them ever stops being reported, that
  # spec says so.

  # `public_send` respects visibility, so this is a `NoMethodError` at runtime even though
  # `stamp` exists. A different error from "no such method" and worth a different message:
  # the name resolves, the call does not.
  def stamped_publicly
    SendDispatch.new.public_send(:stamp, "post")
  end

  # No method by this name, at any visibility. Measured before the fix: Steep already
  # reported the plain spelling of this (`Ruby::NoMethod`) even for a class that declares
  # `method_missing`, so resolving `send` added no new judgment — it removed an exception.
  def missing_name
    SendDispatch.new.send(:no_such_method_anywhere)
  end

  # Right name, wrong number of arguments: `ArgumentError` at runtime.
  def wrong_arity
    SendDispatch.new.send(:stamp, "a", "b", "c")
  end

  # This one was predicted to stay quiet — a splat of unknown length says nothing about how
  # many arguments arrive — and the prediction was wrong, for a reason worth keeping: the
  # DIRECT spelling does not stay quiet either. Measured, `SendDispatch.new.stamp(*args)`
  # against a one-argument method reports `Unexpected positional argument` in Steep today,
  # so `send` reporting it is not a send-specific arity judgment; it is the existing one,
  # reached through a different door. Silencing it only for `send` would make `send` more
  # permissive than the call it stands for. So: baselined, and the imprecision to fix is
  # Steep's handling of splats, not `send`'s.
  def splatted(*args)
    SendDispatch.new.send(:stamp, *args)
  end

  # The shape that will make the most noise in a real codebase, and the reason the
  # diagnostic got an ID of its own to tune: a `respond_to?` guard does not put the method in
  # the RBS, so this errors even though the code is careful. A project that hits a lot of it
  # sets `Ruby::UnresolvedSend` to `:warning` in its Steepfile and ramps.
  def guarded
    target = SendDispatch.new
    target.send(:no_such_method_anywhere) if target.respond_to?(:no_such_method_anywhere)
  end
end
