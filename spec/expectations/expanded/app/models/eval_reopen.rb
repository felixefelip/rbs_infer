# frozen_string_literal: true

# `class_eval` with a CONSTANT receiver is plain Ruby and statically decidable: the
# `def`s inside the block belong to the receiver, exactly as if the class had been
# reopened. Both halves read it now — `ClassEvalExpander` desugars it into a reopen so
# the methods land in this class's RBS, and felixefelip/steep#135 reads the same call
# shape as an implicit `@implements` so `super` inside the block resolves.
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
# receiver — so everything below lands on `EvalReopen` exactly as if it had been
# written inside the body above.
class EvalReopen
  def by_class_eval
    2
  end

  # Parameters go through the same inference as any class body's: `value` is typed
  # from the call site below, and the optional one from its default. Nothing about the
  # desugaring is special-cased for them — the RBS this produces is byte-identical to
  # the same methods written inside `class EvalReopen`.
  def tagged(value, limit = 10)
    "#{value}:#{limit}"
  end

  # The load-bearing half. `super` resolves against the RECEIVER's ancestors
  # (`EvalReopen` -> `EvalReopen::Slots`), not against wherever the block is written —
  # there is no enclosing class or module here at all. It only types because the def
  # belongs to `EvalReopen`, so `-> String` here (rather than `untyped`) is what says
  # both halves agree. This is exactly what a store-accessor override inside
  # `included do` needs.
  def slot
    super || "default"
  end
end

# `module_eval` is an alias of `class_eval`, so a regression that special-cased one
# name shows up here as a missing `by_module_eval`.
class EvalReopen
  def by_module_eval
    :three
  end
end

# NOT the same operation: `instance_eval` defines a SINGLETON method, so this is
# `EvalReopen.by_instance_eval` and never an instance method. Treating every
# `*_eval` block alike would put it on the wrong side, so both halves decline it —
# it stays absent from the RBS below and keeps its baseline entry.
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
    target.by_class_eval
    target.by_module_eval
    target.tagged(:draft)
  end
end
