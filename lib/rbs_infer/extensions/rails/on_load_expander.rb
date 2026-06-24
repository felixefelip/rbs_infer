# frozen_string_literal: true

require "prism"
require_relative "../../project/source_expanders"

module RbsInfer
  module Extensions
    module Rails
      # Desugars `ActiveSupport.on_load :hook do ... end` into a plain
      # `class <MappedClass> ... end` reopening, so the generic
      # multi-target pipeline sees the methods defined on the right class
      # (felixefelip/rbs_infer#38).
      #
      #   ActiveSupport.on_load :active_storage_blob do
      #     def accessible_to?(user); ...; end
      #   end
      #   # becomes:
      #   class ActiveStorage::Blob
      #     def accessible_to?(user); ...; end
      #   end
      #
      # The Rails-specific knowledge lives entirely in LOAD_HOOKS — the
      # core never learns a load-hook symbol. Like CurrentAttributesExpander
      # this is pure Prism (no Rails at runtime) and self-gates on the
      # `on_load` substring, so it is always safe to register by default.
      module OnLoadExpander
        # Built-in `ActiveSupport.on_load` hooks → the class each one
        # reopens. Names mirror the `run_load_hooks`/`on_load` calls across
        # the Rails framework.
        LOAD_HOOKS = {
          "active_record" => "ActiveRecord::Base",
          "active_record_fixture_set" => "ActiveRecord::FixtureSet",
          "active_storage_record" => "ActiveStorage::Record",
          "active_storage_blob" => "ActiveStorage::Blob",
          "active_storage_attachment" => "ActiveStorage::Attachment",
          "active_storage_variant_record" => "ActiveStorage::VariantRecord",
          "action_controller" => "ActionController::Base",
          "action_controller_base" => "ActionController::Base",
          "action_controller_api" => "ActionController::API",
          "action_mailer" => "ActionMailer::Base",
          "action_view" => "ActionView::Base",
          "action_text_content" => "ActionText::Content",
          "action_text_rich_text" => "ActionText::RichText",
          "action_text_encrypted_rich_text" => "ActionText::EncryptedRichText",
          "active_job" => "ActiveJob::Base",
        }.freeze

        module_function

        # Returns the expanded source, or nil when there is nothing to
        # rewrite (no recognized `on_load` block).
        def expand(source)
          return nil unless source.include?("on_load")

          result = Prism.parse(source)
          return nil unless result.success?

          calls = RbsInfer::Analyzer.find_all_nodes(result.value) { |node| on_load_call?(node) }
          replacements = calls.filter_map { |call| replacement_for(source, call) }
          return nil if replacements.empty?

          apply_replacements(source, replacements)
        end

        # `ActiveSupport.on_load :known_hook do ... end` — explicit
        # `ActiveSupport` receiver, a recognized symbol as first argument,
        # and a block to lift into the class body.
        def on_load_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :on_load
          return false unless node.block.is_a?(Prism::BlockNode)

          receiver = node.receiver
          return false unless receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ActiveSupport

          first_arg = node.arguments&.arguments&.first
          first_arg.is_a?(Prism::SymbolNode) && LOAD_HOOKS.key?(first_arg.unescaped)
        end

        def replacement_for(source, call)
          klass = LOAD_HOOKS[call.arguments.arguments.first.unescaped]
          body = call.block.body
          body_source = body ? slice(source, body) : ""

          {
            start: call.location.start_offset,
            end: call.location.end_offset,
            text: "class #{klass}\n#{body_source}\nend",
          }
        end

        def slice(source, node)
          source.byteslice(node.location.start_offset, node.location.end_offset - node.location.start_offset)
        end

        # Applies the replacements back to front so earlier byte offsets
        # stay valid (mirrors CurrentAttributesExpander).
        def apply_replacements(source, replacements)
          out = source.dup
          replacements.sort_by { |r| -r[:start] }.each do |r|
            out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
          end
          out
        end
      end

      # Pure Prism, self-gating — safe to register by default.
      RbsInfer::Project::SourceExpanders.register(OnLoadExpander)
    end
  end
end
