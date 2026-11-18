# frozen_string_literal: true

module RbsInfer
  module Inference
    # The keywords one call site hands a `**rest` parameter, as an RBS record:
    # every keyword that names no declared parameter, `{ }` when there is none.
    # A `**splat` or a key that is not a plain symbol says nothing about which
    # keys arrive, so the call is `Hash[Symbol, untyped]`, which keeps the rest
    # parameter open.
    module KeywordRestRecord
      UNKNOWN = "Hash[Symbol, untyped]"
      KEY = /\A[a-z_][a-zA-Z0-9_]*\z/

      def self.of(arguments, declared:)
        hashes = arguments.grep(Prism::KeywordHashNode)
        fields = hashes.flat_map(&:elements).filter_map do |elem|
          return UNKNOWN unless elem.is_a?(Prism::AssocNode) && (key = symbol_key(elem.key))
          next if declared.include?(key)

          "#{key}: #{yield(elem.value) || "untyped"}"
        end
        "{ #{fields.join(", ")} }"
      end

      def self.symbol_key(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) && node.unescaped.match?(KEY)
      end
    end
  end
end
