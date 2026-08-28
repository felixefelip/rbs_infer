# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # What makes a call a `class_eval`/`module_eval` REOPEN — everything except
  # which class it reopens.
  #
  # The receiver is the one part deliberately left out, because it is the only
  # part the expanders disagree on: `ClassEvalExpander` reads a constant, which
  # names its class outright, and `SelfClassEvalExpander` reads `self.class`,
  # which names it only once you know the method it is written in. Everything
  # else — the two method names, needing a block, and rejecting arguments — is
  # one definition, and was written twice until it wasn't.
  module ReopeningCall
    # `instance_eval` is deliberately absent from both expanders: its default
    # definee is the receiver's SINGLETON class, so rewriting it to `class X`
    # would attribute the def to the instance side — the wrong half.
    # felixefelip/steep#135 declines it for the same reason, which keeps the two
    # sides agreeing.
    METHODS = %w[class_eval module_eval].freeze

    module_function

    # Cheap enough to run before parsing, and every caller does.
    def possible?(source)
      METHODS.any? { |name| source.include?(name) }
    end

    # How many the source writes — the same question `possible?` asks, counted.
    #
    # It is an upper bound on the passes a rewriting expander can need: a pass
    # consumes at least one of these and the reopening it emits carries none
    # (the body is moved byte for byte, so no rewrite can manufacture one), so
    # the count strictly decreases. Loose on purpose — a `class_eval` this
    # expander declines, or the word inside a comment, only inflates a ceiling
    # the loop stops short of anyway.
    def count(source)
      METHODS.sum { |name| source.scan(name).size }
    end

    # The call shape, receiver aside. The STRING form (`class_eval "def x; end"`)
    # is excluded by requiring a block and no arguments: its body is not source
    # this can read, and is the genuinely undecidable case the README reserves
    # for `eval`.
    def shape?(node)
      node.is_a?(Prism::CallNode) &&
        METHODS.include?(node.name.to_s) &&
        node.block.is_a?(Prism::BlockNode) &&
        node.arguments.nil?
    end
  end
end
