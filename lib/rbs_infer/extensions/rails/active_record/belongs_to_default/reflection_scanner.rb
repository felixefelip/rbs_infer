# frozen_string_literal: true

require "prism"
require "active_support/core_ext/string/inflections"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module BelongsToDefault
          # A `belongs_to :owner, class_name: "User", default: -> { post.user }`.
          # `default_body` / `default_location` are set only when a `default:`
          # lambda is present (that's the association whose lambda Steep flags).
          DefaultAssociation = Struct.new(
            :name,           # "owner"
            :class_name,     # "User"
            :default_body,   # "post.user"
            :default_location, # { line:, column:, length: } of the lambda body
            keyword_init: true
          )

          BelongsTo = Struct.new(:name, :class_name, keyword_init: true)
          HasMany   = Struct.new(:name, :class_name, keyword_init: true)

          # One model's reflections relevant to the belongs_to-default expansion.
          ModelReflections = Struct.new(
            :path,                  # project-relative source path
            :class_name,            # "Assignment"
            :belongs_to,            # [BelongsTo]
            :has_many,              # [HasMany]
            :default_associations,  # [DefaultAssociation]
            keyword_init: true
          ) do
            # The `belongs_to` on this model whose target is `owner_class` — the
            # inverse the association-construction path sets (`record.post =
            # owner`). nil when no belongs_to points back at the owner.
            def inverse_belongs_to_for(owner_class)
              belongs_to.find { |b| b.class_name == owner_class }
            end
          end

          # Parses a model source file into `ModelReflections` (one per class in
          # the file, though models are conventionally one-per-file). Returns []
          # when the file defines no class with associations.
          module ReflectionScanner
            module_function

            def scan(path:, source:)
              result = Prism.parse(source)
              return [] unless result.success?

              RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::ClassNode) }
                                .filter_map { |klass| reflections_for(path, source, klass) }
            end

            def reflections_for(path, source, klass)
              class_name = RbsInfer::Analyzer.extract_constant_path(klass.constant_path)
              return nil unless class_name

              belongs_to = []
              has_many = []
              defaults = []

              association_calls(klass).each do |call|
                name = first_symbol(call)
                next unless name

                kwargs = keyword_args(call)
                case call.name
                when :belongs_to
                  belongs_to << BelongsTo.new(name: name, class_name: belongs_to_class(name, kwargs))
                  default = default_association(source, call, name, kwargs)
                  defaults << default if default
                when :has_many
                  has_many << HasMany.new(name: name, class_name: has_many_class(name, kwargs))
                end
              end

              return nil if belongs_to.empty? && has_many.empty?

              ModelReflections.new(
                path: path,
                class_name: class_name,
                belongs_to: belongs_to,
                has_many: has_many,
                default_associations: defaults
              )
            end

            # Receiverless `belongs_to`/`has_many` calls at class-body level (a
            # call nested in a def/block is not the AR macro).
            def association_calls(klass)
              body = klass.body
              statements = case body
                           when Prism::StatementsNode then body.body
                           when nil then []
                           else [body]
                           end

              statements.select do |stmt|
                stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
                  %i[belongs_to has_many].include?(stmt.name) && stmt.arguments
              end
            end

            def first_symbol(call)
              arg = call.arguments&.arguments&.first
              arg.is_a?(Prism::SymbolNode) ? arg.value.to_s : nil
            end

            # { "class_name" => <StringNode|value>, "default" => <node>, ... }
            def keyword_args(call)
              hash = call.arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
              return {} unless hash

              hash.elements.each_with_object({}) do |elem, acc|
                next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)

                acc[elem.key.value.to_s] = elem.value
              end
            end

            def belongs_to_class(name, kwargs)
              explicit = string_value(kwargs["class_name"])
              explicit || name.camelize
            end

            def has_many_class(name, kwargs)
              explicit = string_value(kwargs["class_name"])
              explicit || name.singularize.camelize
            end

            def string_value(node)
              return nil unless node.is_a?(Prism::StringNode)

              node.unescaped
            end

            # A `default:` value that is a lambda/proc → DefaultAssociation with
            # the body source and its location. Anything else (a symbol, a
            # constant) has no nilable-deref risk, so it's skipped.
            def default_association(source, call, name, kwargs)
              node = kwargs["default"]
              body = lambda_body(node)
              return nil unless body

              DefaultAssociation.new(
                name: name,
                class_name: belongs_to_class(name, kwargs),
                default_body: slice(source, body),
                default_location: location_of(source, body)
              )
            end

            def lambda_body(node)
              case node
              when Prism::LambdaNode
                node.body
              when Prism::CallNode
                node.block&.body if %i[lambda proc].include?(node.name)
              end
            end

            def slice(source, node)
              source.byteslice(node.location.start_offset, node.location.end_offset - node.location.start_offset)
            end

            def location_of(source, node)
              loc = node.location
              { line: loc.start_line, column: loc.start_column, length: loc.end_offset - loc.start_offset }
            end
          end
        end
      end
    end
  end
end
