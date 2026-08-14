# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # Renders a `class_eval`/`module_eval` block as the `class X … end` it is, in
  # either of the two places one can go.
  #
  # IN PLACE, where the call itself stands — what `ClassEvalExpander` does, and
  # what it can do because `X.class_eval do … end` sits where a class
  # declaration may also sit.
  #
  # APPENDED at the top level — the only option for the two expanders that
  # relocate a block written somewhere a declaration cannot go: a stored block
  # replayed on another object, and a `self.class.class_eval` inside a method
  # body, where `class X … end` is a SyntaxError rather than merely the wrong
  # scope.
  #
  # One module because the choice between them is about PLACEMENT, and
  # everything else — how the body is sliced, and what that must not disturb —
  # is the same question with the same answer.
  module BlockReopen
    module_function

    # @return [String, nil] a top-level reopening, or nil for a block with no
    #   body — which relocates to nothing, and whose `location` would raise.
    def appended(source:, block:, kind:, target:)
      body = block.body
      return nil unless body

      "#{kind} #{target}\n#{slice_with_indent(source, body)}\nend\n"
    end

    # The text that replaces the call, `class X` landing at the call's own
    # column — so the closing `end` is indented to match rather than to zero.
    def in_place(source:, call:, name:)
      body = call.block.body
      body_source = body ? slice_with_indent(source, body) : ""
      indent = line_indent(source, call.location.start_offset)

      "class #{name}\n#{body_source}\n#{indent}end"
    end

    # The reopenings of `reopens` that `source` does not already carry.
    #
    # An in-place rewrite consumes the call that produced it, so running it again
    # finds nothing and stops. Appending does not: the call stays exactly where it
    # was, so an expander run over its own output appends a second copy of the
    # same reopening, and a third. `SourceExpanders` requires expanders to be
    # idempotent over their own output; for the appending ones, this is what
    # makes them so.
    def missing_from(source, reopens)
      reopens.reject { |reopen| source.include?(reopen) }
    end

    # The body, sliced from the start of its own LINE rather than from its first
    # token, so the indentation the source already had survives.
    #
    # Slicing from the token drops the FIRST line's indentation and nothing
    # else, leaving `def` at column 0 with its own `end` still indented. Legal
    # Ruby, and invisible to the pipeline, but the `.expanded/` sidecar exists to
    # be read while debugging and that made it harder to read than the source it
    # mirrors.
    #
    # Only the indentation is reclaimed — the body is never RE-indented, because
    # that rewrites the contents of any heredoc or multi-line string inside it.
    # An appended reopening is emitted at column 0 and so LOOKS like it wants
    # re-indenting; it did, briefly (felixefelip/rbs_infer#239), and a heredoc
    # written with a deliberate margin came out with a different string in it.
    # Prettier output is not worth changing what the program says.
    def slice_with_indent(source, node)
      start = node.location.start_offset
      scan = start
      scan -= 1 while scan.positive? && [" ", "\t"].include?(source.byteslice(scan - 1, 1))

      # Only when the body genuinely opens its own line. `class_eval do def x; end end`
      # on one line would otherwise pull in the space after `do`.
      start = scan if scan.zero? || source.byteslice(scan - 1, 1) == "\n"

      source.byteslice(start, node.location.end_offset - start)
    end

    # The whitespace between the start of `offset`'s line and `offset`, or ""
    # when anything else precedes it on that line.
    def line_indent(source, offset)
      scan = offset
      scan -= 1 while scan.positive? && [" ", "\t"].include?(source.byteslice(scan - 1, 1))
      return "" unless scan.zero? || source.byteslice(scan - 1, 1) == "\n"

      source.byteslice(scan, offset - scan)
    end
  end
end
