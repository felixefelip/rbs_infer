# frozen_string_literal: true

module RbsInfer
  # Registry of plugins that rewrite the target file's source BEFORE the
  # parse (felixefelip/rbs_infer#19). Each expander desugars macros into
  # plain-Ruby pseudo-code so the inference pipeline sees ordinary defs —
  # the expanded view exists only in memory during generation.
  #
  # The core knows no framework: extensions (from this gem or third
  # parties) register themselves at require time. Expander contract:
  #
  #   expander.expand(source) #=> String (expanded source) | nil (no-op)
  #
  # Expanders must be idempotent over their own output and cheap on the
  # no-op path (gate on a substring before parsing, as
  # CurrentAttributesExpander does with `CurrentAttributes`).
  module SourceExpanders
    @expanders = []

    module_function

    def register(expander)
      @expanders << expander unless @expanders.include?(expander)
      expander
    end

    def unregister(expander)
      @expanders.delete(expander)
    end

    def expanders
      @expanders.dup
    end

    # Applies the expanders in a chain (one's output feeds the next).
    # Returns the final expanded source, or nil when none changed
    # anything — callers use nil to know there is no expanded view.
    def apply(source)
      result = nil
      @expanders.each do |expander|
        expanded = expander.expand(result || source)
        result = expanded if expanded
      end
      result
    end
  end
end
