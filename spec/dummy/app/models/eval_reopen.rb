# frozen_string_literal: true

# `class_eval` with a CONSTANT receiver is plain Ruby and statically decidable: the
# `def`s inside the block belong to the receiver, exactly as if the class had been
# reopened. Neither repo reads it today — rbs_infer drops the methods from the RBS
# and Steep type-checks them at top level (`UndeclaredMethodDefinition`).
#
# It is the shape `ActiveSupport.on_load` is already desugared into
# (`OnLoadExpander`), and the one a concern's `included do` reduces to once the host
# is known: Rails `class_eval`s that block on the includer, which is why an override
# written there can call `super` and one written in the concern's body cannot.
class EvalReopen
  include EvalReopen::Slots

  def own
    "own"
  end
end

# `class_eval` is the same operation as reopening the class, only spelled with a
# receiver — so everything below has to land on `EvalReopen` exactly as if it had
# been written inside the body above. (A literal second `class EvalReopen` body is
# deliberately NOT used as the control here: rbs_infer emits the merged members once
# per reopen, which makes the RBS invalid — see felixefelip/rbs_infer, unrelated to
# this fixture.)
EvalReopen.class_eval do
  def by_class_eval
    2
  end

  # The point of the exercise. `super` has to resolve against the RECEIVER's
  # ancestors (`EvalReopen` -> `EvalReopen::Slots`), not against wherever the block
  # is written — there is no enclosing class or module here at all. This is exactly
  # what a store-accessor override inside `included do` needs.
  def slot
    super || "default"
  end
end

# `module_eval` is an alias of `class_eval`, so a fix that special-cased one name
# shows up here as a missing `by_module_eval`.
EvalReopen.module_eval do
  def by_module_eval
    :three
  end
end

# NOT the same operation: `instance_eval` defines a SINGLETON method, so this is
# `EvalReopen.by_instance_eval` and never an instance method. Treating every
# `*_eval` block alike would put it on the wrong side.
EvalReopen.instance_eval do
  def by_instance_eval
    4.0
  end
end

# Genuinely undecidable — the body is a string, so no static analysis can read the
# def. Out of scope (the README's `eval` exclusion), and here so it stays out rather
# than being half-supported.
EvalReopen.class_eval "def by_string_eval; 5; end"

# The call site the slot's type comes from: inference reads assignments, not
# annotations, so a slot nobody writes stays untyped however it is read.
class EvalReopenCaller
  def fill
    target = EvalReopen.new
    target.slot = "value"
  end
end
