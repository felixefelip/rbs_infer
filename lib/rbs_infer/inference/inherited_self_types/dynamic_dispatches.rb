# frozen_string_literal: true

module RbsInfer
  module Inference
    class InheritedSelfTypes
      # The method names the project's calls by name may invoke: the literals
      # the checker types their name argument as, wherever the name came from.
      # `send(name)` with `name` a parameter every call site passes `:speak`
      # counts `speak`. A name the checker does not know as a literal is
      # computed, and no spelling of it can be found anyway.
      class DynamicDispatches
        DISPATCHERS = %i[send __send__ public_send method public_method instance_method public_instance_method].freeze

        def initialize(source_index:, parse_cache:, steep_bridge:)
          @source_index = source_index
          @parse_cache = parse_cache
          @steep_bridge = steep_bridge
        end

        def names
          files = DISPATCHERS.flat_map { |name| @source_index.files_mentioning(name.to_s) }.uniq
          files.each_with_object(Set.new) { |file, found| found.merge(names_in(file)) }
        end

        private

        def names_in(file)
          entry = @parse_cache.get(file) or return []
          arguments = name_arguments(entry.result.value)
          written = arguments.map { |argument| literal_names(argument) }
          return written.flatten if written.all?

          types = @steep_bridge.all_expression_types(entry.source, file:)
          arguments.zip(written).flat_map { |argument, names| names || typed_names(types, argument) }
        end

        def typed_names(types, argument)
          literal_names_of(types[RbsInfer::Signatures::SteepBridge.prism_expression_key(argument.location)])
        end

        def name_arguments(root)
          RbsInfer::Analyzer.find_all_nodes(root) { |node| node.is_a?(Prism::CallNode) && DISPATCHERS.include?(node.name) }
                            .filter_map { |call| call.arguments&.arguments&.first }
        end

        def literal_names(node)
          [node.unescaped] if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        end

        def literal_names_of(spelled)
          return [] unless spelled

          type = RBS::Parser.parse_type(spelled)
          (type.is_a?(RBS::Types::Union) ? type.types : [type]).filter_map do |member|
            member.literal.to_s if member.is_a?(RBS::Types::Literal) && [Symbol, String].include?(member.literal.class)
          end
        rescue RBS::ParsingError
          []
        end
      end
    end
  end
end
