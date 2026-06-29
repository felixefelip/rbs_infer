# frozen_string_literal: true

require "prism"
require_relative "class_methods_expander"
require_relative "module_self_type_annotator"

module RbsInfer
  module Extensions
    module Rails
      # Computes the `blocks:` sidecar entries that let Steep type-check an
      # `ActiveSupport::Concern`'s `class_methods do … end` correctly
      # (felixefelip/rbs_infer#60, felixefelip/steep#47).
      #
      # `ClassMethodsExpander` desugars such a block into a nested
      # `module ClassMethods` for RBS *generation*. For *source checking*, Steep
      # needs the block body annotated `# @implements <Concern>::ClassMethods`
      # (so the defs attach to ClassMethods) AND, on each method, a `self` that
      # a `class_methods` method actually runs with: the including class's
      # singleton intersected with ClassMethods (felixefelip/steep#47). At
      # runtime self is the includer's singleton, where the includer's
      # scopes/class methods live; the `& ClassMethods` term keeps calls
      # between the block's own methods resolving even when the includer's RBS
      # doesn't `extend ...::ClassMethods`. This emits, per file, both resolved
      # values so Steep's `ModuleSelfTypes` injector can place the annotations,
      # without Steep ever learning the `class_methods` DSL.
      #
      # Detection reuses `ClassMethodsExpander.class_methods_block?` so the
      # sidecar and the RBS desugar agree on exactly what a `class_methods`
      # block is. The including class is derived by the same rule
      # `ModuleSelfTypeAnnotator` uses for the concern self-type.
      module ClassMethodsImplements
        CALL = "class_methods"

        module_function

        # @param path [String] source path (for the including-class rule)
        # @param module_name [String] the concern's FQN from the AST (e.g.
        #   "Post::Taggable")
        # @param source [String] the file's source
        # @return [Array<Hash>] `[{ "call" => "class_methods", "implements" =>
        #   "::<FQN>::ClassMethods"[, "self" => "singleton(::<Includer>) &
        #   ::<FQN>::ClassMethods"] }]` when `source` has at least one
        #   receiverless `class_methods do` block, else `[]`. `self` is omitted
        #   when no including class can be derived (e.g. a top-level concern).
        def blocks_for(path:, module_name:, source:)
          return [] if module_name.nil? || module_name.empty?
          return [] unless source.include?(CALL)

          result = Prism.parse(source)
          return [] unless result.success?

          has_block = RbsInfer::Analyzer
                      .find_all_nodes(result.value) { |node| ClassMethodsExpander.class_methods_block?(node) }
                      .any?
          return [] unless has_block

          class_methods = "::#{module_name}::ClassMethods"
          entry = { "call" => CALL, "implements" => class_methods }
          if (including = ModuleSelfTypeAnnotator.including_class_for(path, module_name))
            entry["self"] = "singleton(::#{including}) & #{class_methods}"
          end
          [entry]
        end
      end
    end
  end
end
