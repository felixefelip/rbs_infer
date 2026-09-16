# Array operations over literal elements — S1 of felixefelip/steep#171.
#
# Every return below is decided by reading the file: the receivers are arrays
# whose elements are literals written here, and the methods are pure core calls
# on them.
#
# S1 landed over two steps: felixefelip/steep#172 brought `join`, and
# felixefelip/steep#184 brought the two that answer by DISPATCHING, once an
# entry could declare the methods it leans on. One line is still open, and it is
# held up by something other than the fold — the reason is written beside it.
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
    # branch, and nine of the checker's own tests are written that way.
    def first_chunk
      ["def #{name}", "end"].first
    end

    # type should be literal `false` — `'content'` is none of them. It took two
    # fixes, one per repo, and the second would have held it even alone.
    # `::Array#include?` answers by dispatching `==`, so it only joined the
    # fold's table once an entry could name what it leans on (steep#184). And
    # `literal_refinement?` asked that a literal's widening EQUAL the declared
    # type, which `false` failed — it widens to `FalseClass`, not `bool` (#357).
    def reserved_name
      ["class", "def", "end"].include?(name)
    end

    # type should be literal `true` — the same two as `reserved_name`
    # (`intersect?` answers through `eql?`/`hash`, so it names those instead).
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

    # type should be literal `'def content;end;# content'`
    #
    # It said STAY `String` until S3, and S3's first half did not move it: the
    # receiver is a local, and neither its node nor its type offers a tuple.
    # What moved it is reading the PUSHES — a local born from an array literal
    # and pushed to in the body's straight line carries what went into it.
    #
    # Written with two seed elements on purpose. A ONE-element array literal
    # keeps its element literal — `["def #{name}"]` infers
    # `Array['def content']` — and the `<<` below is then a type error rather
    # than a widening, which is also why the contents are handed to the fold
    # rather than written back onto the local.
    def accumulated
      parts = ["def #{name}", "end"]
      parts << "# #{name}"
      parts.join(";")
    end
  end
end
