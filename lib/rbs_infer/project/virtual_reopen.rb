# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # Renders a block whose `def`s belong to some class OTHER than the one the
  # block is written in as a top-level reopening of that class.
  #
  # Appending is not a stylistic choice. `ClassEvalExpander` rewrites
  # `X.class_eval do … end` IN PLACE, which it can because the call sits where a
  # `class X … end` may also sit. The two expanders that use this one cannot: a
  # stored block is written in one object and replayed on another, and a
  # `self.class.class_eval` sits inside a method body — where `class X … end` is
  # not merely wrong but a SyntaxError. The relocated body has to be emitted
  # somewhere a class declaration is legal, which is the top level.
  #
  # Shared so the two agree on what a relocated block looks like, down to the
  # indentation: they produce the debug `.expanded/` view a human reads, and
  # `spec/expectations/expanded/` pins it.
  module VirtualReopen
    module_function

    # @param source [String] the file the block was read from
    # @param block [Prism::BlockNode] the block being relocated
    # @param kind [String] "class" or "module", as the TARGET is declared
    # @param target [String] the target's qualified name
    # @return [String, nil] the reopening, or nil for a block with no body —
    #   which relocates to nothing, and whose `location` would otherwise raise.
    def build(source:, block:, kind:, target:)
      body = block.body
      return nil unless body

      length = body.location.end_offset - body.location.start_offset
      body_source = source.byteslice(body.location.start_offset, length)
      # Prism's body range starts at its first token, dropping the whitespace
      # that indented that line in the source. The virtual reopening is
      # top-level, so normalize that common margin to its conventional two
      # spaces while preserving every indentation level beneath it.
      "#{kind} #{target}\n#{reindent(body_source, line_indent(source, body.location.start_offset))}\nend\n"
    end

    # The whitespace between the start of `offset`'s line and `offset` itself,
    # or "" when anything else precedes it on that line.
    def line_indent(source, offset)
      scan = offset
      scan -= 1 while scan.positive? && [" ", "\t"].include?(source.byteslice(scan - 1, 1))
      return "" unless scan.zero? || source.byteslice(scan - 1, 1) == "\n"

      source.byteslice(scan, offset - scan)
    end

    def reindent(body_source, source_indent)
      return "  #{body_source}" if source_indent.empty?

      # The first line starts at Prism's first token and therefore has no
      # source margin in `body_source`; following lines still have it.
      ["  ", body_source.gsub(/(?<=\n)#{Regexp.escape(source_indent)}/, "  ")].join
    end
  end
end
