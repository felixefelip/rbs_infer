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

    # One level in, from whatever `class X` the body ends up under.
    INDENT = "  "

    # Every node whose bytes are a literal's own, and so are not the program's
    # indentation to change. Listed rather than duck-typed on `content_loc`,
    # which `CallNode` and friends do not have but `EmbeddedStatementsNode`
    # nearly does — the question is "is this a literal", not "does it look like
    # one".
    LITERALS = [
      Prism::StringNode,
      Prism::InterpolatedStringNode,
      Prism::XStringNode,
      Prism::InterpolatedXStringNode,
      Prism::RegularExpressionNode,
      Prism::InterpolatedRegularExpressionNode,
      Prism::SymbolNode,
      Prism::InterpolatedSymbolNode,
      Prism::MatchLastLineNode,
      Prism::InterpolatedMatchLastLineNode
    ].freeze

    # @return [String, nil] a top-level reopening, or nil for a block with no
    #   body — which relocates to nothing, and whose `location` would raise.
    def appended(source:, block:, kind:, target:)
      body = block.body
      return nil unless body

      "#{kind} #{target}\n#{body_source(source, body, indent: INDENT)}\nend\n"
    end

    # The text that replaces the call, `class X` landing at the call's own
    # column — so the closing `end` is indented to match rather than to zero.
    def in_place(source:, call:, name:)
      body = call.block.body
      indent = line_indent(source, call.location.start_offset)
      body_source = body ? body_source(source, body, indent: indent + INDENT) : ""

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
    # token so the source's own indentation comes along, then moved as a whole so
    # its outermost line sits at `indent`.
    #
    # Slicing from the token drops the FIRST line's indentation and nothing
    # else, leaving `def` at column 0 with its own `end` still indented. Legal
    # Ruby, and invisible to the pipeline, but the `.expanded/` sidecar exists to
    # be read while debugging and that made it harder to read than the source it
    # mirrors.
    #
    # The relocation is what makes the move necessary rather than cosmetic: a
    # block written two or three scopes deep is emitted under a reopening at
    # column 0, so every line keeps a margin that no longer corresponds to
    # anything. `realigned` is what removes it — see there for what it will not
    # touch, and why.
    def body_source(source, node, indent:)
      start = node.location.start_offset
      scan = start
      scan -= 1 while scan.positive? && [" ", "\t"].include?(source.byteslice(scan - 1, 1))

      # Only when the body genuinely opens its own line. `class_eval do def x; end end`
      # on one line would otherwise pull in the space after `do`.
      start = scan if scan.zero? || source.byteslice(scan - 1, 1) == "\n"

      text = source.byteslice(start, node.location.end_offset - start)
      realigned(text, literal_spans(node).map { |span| (span.begin - start)...(span.end - start) }, indent)
    end

    # `text` with the shallowest line brought to `indent` and every other line
    # moved by the same amount, so the body's own shape is preserved.
    #
    # What is NOT moved is any line that is string DATA. Re-indenting the whole
    # slice rewrites the contents of any heredoc or multi-line string inside it;
    # that shipped briefly (felixefelip/rbs_infer#239) and a heredoc written with
    # a deliberate margin came out with a different string in it. The lesson was
    # taken then as "never re-indent", which is stronger than the problem: the
    # hazard is the DATA, and `literal_spans` says exactly where that is. Lines
    # inside one are emitted byte for byte, which is also why a `<<~` margin
    # survives — Ruby computes it from those lines alone, and they did not move.
    #
    # `=begin`/`=end` are the one hazard Prism does not report as a node — they
    # are comments, and they are only comments at column 0. Rather than move them
    # to a column where they stop being comments, the whole slice stays put.
    def realigned(text, spans, indent)
      lines = text.lines
      offset = 0
      starts = lines.map { |line| offset.tap { offset += line.bytesize } }

      movable = lines.each_index.reject do |index|
        lines[index].strip.empty? || spans.any? { |span| span.cover?(starts[index]) }
      end
      return text if movable.empty?
      return text if movable.any? { |index| lines[index].start_with?("=begin", "=end") }

      margin = movable.map { |index| lines[index][/\A[ \t]*/].length }.min
      movable.each { |index| lines[index] = "#{indent}#{lines[index][margin..]}" }
      lines.join
    end

    # A literal's span carries its OPENING and CLOSING too, not just its
    # content: for a heredoc the closing is the terminator line, whose column is
    # fixed for `<<X` and load-bearing for nothing in the body either way, and
    # covering the opening costs nothing since it never starts a line the body
    # would move.
    #
    # Descent stops AT a literal, so an interpolation inside one is left alone
    # with the rest of it. Moving those lines would in fact be safe — Ruby
    # measures a `<<~` margin against the content lines only — but "a literal is
    # one span" needs no such argument, and the argument would have to be remade
    # for every literal that later grows an interpolation.
    def literal_spans(node)
      spans = []
      stack = [node]

      until stack.empty?
        current = stack.pop
        if literal?(current)
          spans << literal_span(current)
        else
          stack.concat(current.compact_child_nodes)
        end
      end

      spans
    end

    def literal?(node)
      LITERALS.any? { |type| node.is_a?(type) }
    end

    def literal_span(node)
      opening = node.respond_to?(:opening_loc) ? node.opening_loc : nil
      closing = node.respond_to?(:closing_loc) ? node.closing_loc : nil

      (opening&.end_offset || node.location.start_offset)...(closing&.end_offset || node.location.end_offset)
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
