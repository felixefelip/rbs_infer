# `delegate`, read from ActiveSupport's own source (felixefelip/rbs_infer#355).
#
# The three call sites the hand-written reader could not read, which the
# transcription reads for free because nothing reads the macro any more:
#
#   - `to: :author` — the reader guessed the receiver's class by capitalizing
#     the reader's NAME, so a reader not named after its class (`author`
#     returns a `User`) typed as `untyped`. The generated body is
#     `_ = author; _.full_name(...)`, an ordinary call, and `author`'s return
#     is what types it;
#   - `to: :@owner` — a symbol naming an ivar was read as a class named
#     `"@owner"`. The body reads the ivar;
#   - `to: Shelf` — a constant receiver was not a symbol, so the whole call was
#     dropped. ActiveSupport reflects on `Shelf.fetch` and writes its parameter
#     list, `(key, &)`.
#
# Nothing here states a type.
class Example81
  module Shelf
    def self.fetch(key) = key.upcase
  end

  def initialize
    @owner = User.new
  end

  def author = User.new

  delegate :full_name, to: :author
  delegate :full_name, to: :@owner, prefix: :owner
  delegate :fetch, to: Shelf
end
