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

  def run
    with_token { |token| token.upcase }
  end
end
