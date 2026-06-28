# frozen_string_literal: true

require "prism"
require_relative "../../project/source_expanders"

module RbsInfer
  module Extensions
    module Rails
      # Desugars an `ActiveSupport::Concern`'s `class_methods do ... end`
      # block into a plain nested `module ClassMethods ... end`, so the
      # generic pipeline attributes the defs to that module on its own —
      # the exact convention `RbsBuilder` already expects on the consumer
      # side (`extend ...::ClassMethods`).
      #
      #   module Greetable
      #     extend ActiveSupport::Concern
      #     class_methods do
      #       def banner; "hi"; end
      #     end
      #   end
      #   # becomes:
      #   module Greetable
      #     extend ActiveSupport::Concern
      #     module ClassMethods
      #       def banner; "hi"; end
      #     end
      #   end
      #
      # The Concern-specific knowledge lives entirely here — the core never
      # learns the `class_methods` DSL. Like the other expanders this is
      # pure Prism (no Rails at runtime) and self-gates on the
      # `class_methods` substring, so it is always safe to register by
      # default (felixefelip/rbs_infer#60).
      module ClassMethodsExpander
        MODULE_NAME = "ClassMethods"

        module_function

        # Returns the expanded source, or nil when there is nothing to
        # rewrite (no recognized `class_methods do` block).
        def expand(source)
          return nil unless source.include?("class_methods")

          result = Prism.parse(source)
          return nil unless result.success?

          calls = RbsInfer::Analyzer.find_all_nodes(result.value) { |node| class_methods_block?(node) }
          replacements = calls.map { |call| replacement_for(source, call) }
          return nil if replacements.empty?

          apply_replacements(source, replacements)
        end

        # The receiverless `class_methods do/{ }` call shape — the name
        # alone is distinctive to the Concern DSL. No arguments are passed
        # to `class_methods`, so a stray method named `class_methods` taking
        # args (and a block) is left untouched.
        def class_methods_block?(node)
          return false unless node.is_a?(Prism::CallNode)

          node.name == :class_methods &&
            node.receiver.nil? &&
            node.arguments.nil? &&
            node.block.is_a?(Prism::BlockNode)
        end

        def replacement_for(source, call)
          body = call.block.body
          body_source = body ? slice(source, body) : ""

          {
            start: call.location.start_offset,
            end: call.location.end_offset,
            text: "module #{MODULE_NAME}\n#{body_source}\nend",
          }
        end

        def slice(source, node)
          source.byteslice(node.location.start_offset, node.location.end_offset - node.location.start_offset)
        end

        # Applies the replacements back to front so earlier byte offsets
        # stay valid (mirrors OnLoadExpander / CurrentAttributesExpander).
        def apply_replacements(source, replacements)
          out = source.dup
          replacements.sort_by { |r| -r[:start] }.each do |r|
            out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
          end
          out
        end
      end

      # Pure Prism, self-gating — safe to register by default.
      RbsInfer::Project::SourceExpanders.register(ClassMethodsExpander)
    end
  end
end
