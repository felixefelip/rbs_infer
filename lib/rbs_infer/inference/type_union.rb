# frozen_string_literal: true

module RbsInfer
  module Inference
    module TypeUnion
      BOOLEANS = %w[true false bool].freeze

      class << self
        # Unions a list of types (from distinct call-sites) into a single RBS
        # string. `untyped` is dropped when at least one resolved type exists.
        # Pre-existing unions (`(String | Symbol)`) are flattened via the RBS
        # parser, so combining partial results (intra-class + cross-class) is
        # associative and idempotent — no nested parens, no duplicate members.
        def of(types)
          flat = types.flat_map { |t| flatten_union(t) }
          resolved = flat.reject { |t| t == "untyped" }
          resolved = flat if resolved.empty?

          spell(collapse_subsumed(unique(resolved)))
        end

        # Drops members another member already covers — which de-duplication can't
        # catch, because the two are genuinely different types that happen to nest:
        # `bool` contains both constants, `true | false` spans all of it, and a
        # literal is a subtype of its own class, so `String | ""` IS `String`.
        #
        # All three shapes come from a call on a nilable receiver, whose two branches
        # answer with opposite constants: `ActiveRecord::Core#present?: () -> true`
        # against `NilClass#present?: () -> false`, `Object#present?: () -> bool`
        # against that same `false`, `Integer#to_s: () -> String` against
        # `NilClass#to_s: () -> ""`. Left alone they'd emit a union where the plain
        # type is both shorter and exactly as precise.
        def collapse_subsumed(members)
          return members if members.size < 2

          members = collapse_booleans(members)
          covered = members.to_set { |m| canonical_key(m) }
          members.reject { |m| (cls = literal_class_name(m)) && covered.include?(cls) }
        end

        # The class a literal type is an instance of ("String" for `""`), or nil
        # when the type isn't a literal. `true`/`false` are literals too, but they
        # are handled by the `bool` rule above — TrueClass/FalseClass are not how
        # RBS spells that union.
        def literal_class_name(type)
          parsed = RBS::Parser.parse_type(type)
          return nil unless parsed.is_a?(RBS::Types::Literal)

          case parsed.literal
          when ::String then "String"
          when ::Symbol then "Symbol"
          when ::Integer then "Integer"
          end
        rescue RBS::ParsingError, RBS::BaseError
          nil
        end

        # The identity of a type for dedup purposes, so two SPELLINGS of one type collapse.
        # A textual key does not: the same intersection reaches the merger as
        # `(Post & Post::Validated)` when read back from an RBS declaration and as
        # `Post & Post::Validated` from Steep, and unioning them yielded
        # `((Post & Post::Validated) | Post & Post::Validated)`. The RBS parser already
        # canonicalizes redundant parens; the `::` strip stays because it is a naming
        # convention (cross-class output omits the prefix), not something the parser touches.
        def canonical_key(type)
          RBS::Parser.parse_type(type).to_s.sub(/\A::/, "")
        rescue RBS::ParsingError, RBS::BaseError
          type.sub(/\A::/, "")
        end

        # Flattens a type into its set of top-level union members.
        # `(String | Symbol)` → `["String", "Symbol"]`, `User?` → `["User", "nil"]`;
        # non-union types (incl. generics like `Array[A | B]`) are left intact.
        def flatten_union(type_str)
          members(RBS::Parser.parse_type(type_str)) || [type_str]
        rescue RBS::ParsingError, RBS::BaseError
          [type_str]
        end

        private

        # Dedup by the canonical form, keeping the original spelling of the first
        # occurrence — a single type is emitted verbatim, so absolute names
        # (`::MyApp::Entity`) stay intact.
        def unique(types)
          types.uniq { |type| canonical_key(type) }
        end

        def collapse_booleans(members)
          keys = members.map { |m| canonical_key(m) }
          at = bool_position(keys) or return members

          members.each_index.filter_map do |i|
            if i == at then "bool"
            elsif !BOOLEANS.include?(keys[i]) then members[i]
            end
          end
        end

        # Where `bool` goes: where it already is, or where `true` was when both
        # constants are present.
        def bool_position(keys)
          keys.index("bool") || (keys.include?("false") && keys.index("true"))
        end

        def spell(members)
          return members.first if members.size == 1

          present = members.reject { |type| type == "nil" }
          return "(#{members.join(" | ")})" if present.size == members.size

          RbsInfer::Signatures::RbsParserUtil.nilablize(present.size == 1 ? present.first : "(#{present.join(" | ")})")
        end

        def members(type)
          case type
          when RBS::Types::Union then type.types.flat_map { |member| members(member) || [member.to_s] }
          when RBS::Types::Optional then (members(type.type) || [type.type.to_s]) + ["nil"]
          when RBS::Types::Bases::Nil then ["nil"]
          end
        end
      end
    end
  end
end
