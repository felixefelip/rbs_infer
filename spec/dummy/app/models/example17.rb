# Block parameters, and whether they are optional.
#
# A method that calls its block without guarding it cannot be called without
# one — the block is REQUIRED, and `block.call` is not a call on a possibly-nil
# value. Inferring `?{ … }` for it makes the checker refuse the very line the
# method exists for, which is what `with_token` below reproduces:
#
#   Type `(^(untyped) -> untyped | nil)` does not have method `call`
#
# This is not hypothetical. It is the one error left in the transcription of
# Rails' own `authenticate_or_request_with_http_token` chain
# (sig/generated/steep_controller_runtime/action_controller/metal/), where the
# framework calls `login_procedure.call(token, options)` unconditionally.
#
# `with_optional` is the contrast the fix has to respect: guarded by `if block`,
# optional is the correct answer there. And `with_yield` shows a second gap —
# a method that yields is inferred as taking no block at all.
#
# The block's PARAMETERS come from the same evidence: whatever the body hands
# to the block is what the block receives. `with_pair` and `with_either` below
# pin that (felixefelip/rbs_infer#148) — including the case where the argument
# is not a literal, which is the shape the Rails chain has.
class Example17
  # Required: called unconditionally.
  def with_token(&block)
    block.call("token")
  end

  # Optional: the guard is what makes it so.
  def with_optional(&block)
    block.call("token") if block
  end

  # Yields rather than naming the block.
  def with_yield
    yield "token"
  end

  # The block's PARAMETER TYPES are whatever the method passes to it, which is
  # a question about expressions the checker has already typed — here a local
  # assigned from a call, not a literal, which is the shape Rails' own
  # `login_procedure.call(token, options)` has.
  def with_pair(&block)
    label = name.upcase
    block.call(label, label.length)
  end

  # Two sites, two types, one block parameter: the union is what both sites
  # agree the block must accept.
  def with_either(flag)
    if flag
      yield "text"
    else
      yield 42
    end
  end

  # Forwarding says nothing on its own, so the CALLEE settles it: `with_token`
  # cannot run without a block, so neither can this — and it inherits the shape
  # too (felixefelip/rbs_infer#149).
  def forward_required(&block)
    with_token(&block)
  end

  # The same forward into a callee that tolerates no block stays optional.
  def forward_optional(&block)
    with_optional(&block)
  end

  # And a guard outranks the callee: the author is saying the block is optional
  # here whatever `with_token` demands, and they are right — with no block the
  # call never happens.
  def forward_guarded(&block)
    with_token(&block) if block
  end

  def name
    "example"
  end

  def run
    with_token { |token| token.upcase }
  end
end
