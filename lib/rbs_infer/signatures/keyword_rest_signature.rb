# frozen_string_literal: true

module RbsInfer
  module Signatures
    # The keywords a `**rest` parameter is declared as, from the union of the
    # records its call sites pass (`KeywordRestRecord`): a key every call passes
    # is required, any other optional, and its type is the union of what the
    # calls pass. Nil while some call is not a record, which leaves the rest open.
    module KeywordRestSignature
      def self.keywords(type)
        records = records(type) or return

        records.flat_map { |record| record.all_fields.keys }.uniq.map { |key| keyword(key, records) }.join(", ")
      end

      def self.keyword(key, records)
        fields = records.filter_map { |record| record.all_fields[key] }
        required = fields.size == records.size && fields.all? { |_, req| req }
        "#{"?" unless required}#{key}: #{Inference::TypeUnion.of(fields.map { |field, _| field.to_s })}"
      end

      def self.records(type)
        parsed = RBS::Parser.parse_type(type)
        members = parsed.is_a?(RBS::Types::Union) ? parsed.types : [parsed]
        members if members.all?(RBS::Types::Record)
      rescue RBS::ParsingError
        nil
      end

      def self.apply(signature, name, type)
        keywords = keywords(type) or return signature

        rest = /\*\*untyped #{Regexp.escape(name)}\b/
        return signature.sub(rest, keywords) unless keywords.empty?

        signature.sub(/, #{rest}/, "").sub(/#{rest}(, )?/, "")
      end
    end
  end
end
