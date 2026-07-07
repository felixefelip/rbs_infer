# frozen_string_literal: true

require "prism"
require "active_support/core_ext/string/inflections"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module Runtime
          BelongsTo = Struct.new(:name, :class_name, keyword_init: true)
          HasMany   = Struct.new(:name, :class_name, keyword_init: true)

          # One model's reflections relevant to the AR-runtime pseudo-code:
          # the associations (to wire construction) and the `before_validation`
          # callback method names (the flow that derefs a nilable belongs_to).
          ModelReflections = Struct.new(
            :path,                        # project-relative source path
            :class_name,                  # "Assignment"
            :belongs_to,                  # [BelongsTo]
            :has_many,                    # [HasMany]
            :before_validation_callbacks, # ["log_post_user_name", ...]
            keyword_init: true
          ) do
            # The `belongs_to` on this model whose target is `owner_class` — the
            # inverse the association-construction path sets (`record.post =
            # owner`). nil when no belongs_to points back at the owner.
            def inverse_belongs_to_for(owner_class)
              belongs_to.find { |b| b.class_name == owner_class }
            end
          end

          # Parses a model source into `ModelReflections` (one per class in the
          # file). Returns [] when the file defines no class with associations
          # or before_validation callbacks.
          module ReflectionScanner
            module_function

            def scan(path:, source:)
              result = Prism.parse(source)
              return [] unless result.success?

              RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::ClassNode) }
                                .filter_map { |klass| reflections_for(path, source, klass) }
            end

            def reflections_for(path, source, klass)
              class_name = RbsInfer::Analyzer.extract_constant_path(klass.constant_path)&.delete_prefix("::")
              return nil unless class_name

              belongs_to = []
              has_many = []
              callbacks = []

              macro_calls(klass).each do |call|
                case call.name
                when :belongs_to
                  name = first_symbol(call) or next
                  belongs_to << BelongsTo.new(name: name, class_name: belongs_to_class(name, call))
                when :has_many
                  name = first_symbol(call) or next
                  has_many << HasMany.new(name: name, class_name: has_many_class(name, call))
                when :before_validation
                  callbacks.concat(symbol_args(call))
                end
              end

              return nil if belongs_to.empty? && has_many.empty? && callbacks.empty?

              ModelReflections.new(
                path: path,
                class_name: class_name,
                belongs_to: belongs_to,
                has_many: has_many,
                before_validation_callbacks: callbacks
              )
            end

            # Receiverless macro calls at class-body level (a call nested in a
            # def/block is not the AR class macro).
            def macro_calls(klass)
              body = klass.body
              statements = case body
                           when Prism::StatementsNode then body.body
                           when nil then []
                           else [body]
                           end

              statements.select do |stmt|
                stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
                  %i[belongs_to has_many before_validation].include?(stmt.name) && stmt.arguments
              end
            end

            def first_symbol(call)
              arg = call.arguments&.arguments&.first
              arg.is_a?(Prism::SymbolNode) ? arg.value.to_s : nil
            end

            # All leading symbol arguments (`before_validation :a, :b, if: ...`
            # → ["a", "b"]); stops at the first non-symbol (the kwargs hash).
            def symbol_args(call)
              call.arguments.arguments.take_while { |a| a.is_a?(Prism::SymbolNode) }.map { |a| a.value.to_s }
            end

            def belongs_to_class(name, call)
              string_kwarg(call, "class_name") || name.camelize
            end

            def has_many_class(name, call)
              string_kwarg(call, "class_name") || name.singularize.camelize
            end

            def string_kwarg(call, key)
              hash = call.arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
              return nil unless hash

              assoc = hash.elements.find do |elem|
                elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode) && elem.key.value.to_s == key
              end
              assoc&.value.is_a?(Prism::StringNode) ? assoc.value.unescaped : nil
            end
          end
        end
      end
    end
  end
end
