# frozen_string_literal: true

require "prism"
require_relative "class_methods_expander"

module RbsInfer
  module Extensions
    module Rails
      # Computes the `blocks:` sidecar entries that let Steep type-check an
      # `ActiveSupport::Concern`'s `class_methods do … end` correctly
      # (felixefelip/rbs_infer#60, felixefelip/steep#47).
      #
      # `ClassMethodsExpander` desugars such a block into a nested
      # `module ClassMethods` for RBS *generation*. For *source checking*, Steep
      # needs the block body annotated `# @implements <Concern>::ClassMethods` —
      # the symmetric counterpart. This emits, per file, the resolved target so
      # Steep's `ModuleSelfTypes` injector can place that annotation, without
      # Steep ever learning the `class_methods` DSL.
      #
      # Detection reuses `ClassMethodsExpander.class_methods_block?` so the
      # sidecar and the RBS desugar agree on exactly what a `class_methods`
      # block is.
      module ClassMethodsImplements
        CALL = "class_methods"

        module_function

        # @param module_name [String] the concern's FQN from the AST (e.g.
        #   "Post::Taggable")
        # @param source [String] the file's source
        # @return [Array<Hash>] `[{ "call" => "class_methods", "implements" =>
        #   "::<FQN>::ClassMethods" }]` when `source` has at least one
        #   receiverless `class_methods do` block, else `[]`.
        def blocks_for(module_name:, source:)
          return [] if module_name.nil? || module_name.empty?
          return [] unless source.include?(CALL)

          result = Prism.parse(source)
          return [] unless result.success?

          has_block = RbsInfer::Analyzer
                      .find_all_nodes(result.value) { |node| ClassMethodsExpander.class_methods_block?(node) }
                      .any?
          return [] unless has_block

          [{ "call" => CALL, "implements" => "::#{module_name}::ClassMethods" }]
        end
      end
    end
  end
end
