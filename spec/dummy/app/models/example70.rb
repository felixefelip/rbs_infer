# Array operations over literal elements — S1 of felixefelip/steep#171.
#
# Every return below is decided by reading the file: the receivers are arrays
# whose elements are literals written here, and the methods are pure core calls
# on them.
#
# S1 landed in felixefelip/steep#172 and `joined` and `body` now answer their
# literals. The three that do not are each held up by something OTHER than the
# fold, and the reason is written beside each one — a line still reading
# `String` here is not the same gap it was.
#
# Two of the cases are here for shapes the fix had to get right, not for extra
# coverage:
#
# - `joined` mixes an interpolation with a plain `"end"`. The interpolation
#   folds on its own; the plain string does not survive into the array's element
#   type, which infers `Array['def content' | String]`. So the tuple has to be
#   read off the NODE, the way `literal_operand_type` already reads `:str` and
#   `:sym`, and not off the receiver's type.
# - `body` joins to more than `MAX_LITERAL_WIDTH` (64). That budget bounds bytes
#   a fold COMPUTES — `'x' * 1000`, `2 ** 4096` — and these bytes are all
#   already in the file, like the ones the `dstr` path folds, which has no cap.
module Example70
  class Foo
    def name
      "content"
    end

    # type should be literal `'def content;end'`
    def joined
      ["def #{name}", "end"].join(";")
    end

    # type should be literal `'def content'` — open on purpose. `::Array#first`
    # folds as safely as the others and is held out of the table until the stage
    # that uses it (`parameters.map(&:first)`, S2/S3), because sharpening
    # `[1].first` to `1` makes the `return unless a` after it an unreachable
    # branch, and eight of the checker's own tests are written that way.
    def first_chunk
      ["def #{name}", "end"].first
    end

    # type should be literal `false` — `'content'` is none of them. Two things
    # hold it, and the second would hold it even without the first.
    # `::Array#include?` left the fold's table in review: it answers by
    # dispatching `==`, and the table watches its own methods rather than the
    # ones an entry leans on, so it returns with that tracking in S2/S3. And
    # `literal_refinement?` asks that a literal's widening EQUAL the declared
    # type, which `false` fails — it widens to `FalseClass`, not `bool` (#357).
    def reserved_name
      ["class", "def", "end"].include?(name)
    end

    # type should be literal `true` — held by the same two as `reserved_name`
    # (`intersect?` answers through `eql?`/`hash`).
    def optional_params
      [:req, :opt].intersect?([:opt, :rest, :keyreq])
    end

    # type should be literal, all 98 bytes of it
    def body
      [
        "def #{name}",
        "  rich_text_#{name} || build_rich_text_#{name}",
        "end",
        "def #{name}?",
        "  #{name}.present?",
        "end"
      ].join("\n")
    end

    # type should STAY `String` — `part` is not a literal, so the array is not a
    # tuple of literals and there is nothing to fold
    def joined_with_unknown(part)
      ["def #{name}", part].join(";")
    end

    # type should STAY `String` until S3 — the receiver is a local whose node is
    # an `lvar` and whose type is an `Array`, so neither the syntax nor the type
    # offers a tuple. This is the shape `ActiveSupport::Delegation` actually
    # uses, which is why S1 alone does not move `delegate`.
    #
    # Written with two elements on purpose. A ONE-element array literal keeps
    # its element literal — `["def #{name}"]` infers `Array['def content']` —
    # and the `<<` below is then a type error rather than a widening. Worth
    # knowing for S1: some arrays do carry literals in their type, just never as
    # a tuple.
    def accumulated
      parts = ["def #{name}", "end"]
      parts << "# #{name}"
      parts.join(";")
    end
  end
end
