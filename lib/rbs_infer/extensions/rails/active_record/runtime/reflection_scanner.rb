# frozen_string_literal: true

require "prism"
require "active_support/core_ext/string/inflections"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module Runtime
          BelongsTo = Struct.new(:name, :class_name, :default_body, keyword_init: true)

          # `through`/`source` are the `has_many :through` options, kept raw
          # because the element's class is NOT knowable from this file: it lives
          # on the model the chain hops to (`has_many :assignees, through:
          # :assignments` is `User`, because `Assignment belongs_to :assignee,
          # class_name: "User"`). `class_name` here is the conventional guess
          # from the association name, which the resolver only falls back to.
          HasMany   = Struct.new(:name, :class_name, :through, :source, keyword_init: true)

          # `before_validation :a, :b` — one entry per macro call, so the
          # declaration ORDER survives the concern splice (Rails runs the
          # callbacks in registration order, and a concern registers at the
          # point of `include`).
          BeforeValidation = Struct.new(:names, keyword_init: true)

          # `include SomeConcern` in a class or module body, kept in place
          # among the macros so the concern's own declarations splice in at
          # exactly the position Rails registers them.
          Include = Struct.new(:name, keyword_init: true)

          # One class's (or concern's) reflections relevant to the AR-runtime
          # pseudo-code: the associations (to wire construction), the
          # `before_validation` callback names (the flow that derefs a nilable
          # belongs_to), and the `include`s that contribute more of both.
          #
          # `body` is the ORDERED entry list as written; the readers below are
          # the resolved view of it. A class's body still holds `Include`
          # entries until `ConcernResolver` expands them.
          ModelReflections = Struct.new(
            :path,       # project-relative source path
            :class_name, # "Assignment"
            :kind,       # :class | :module (a concern)
            :body,       # [BelongsTo | HasMany | BeforeValidation | Include]
            keyword_init: true
          ) do
            # A later declaration of the same association REPLACES the earlier
            # one (Rails redefines the reflection), so the class's own macro
            # wins over one a concern registered at include time — and a
            # `has_many` declared in BOTH places yields a single getter rather
            # than two colliding ones.
            def belongs_to
              last_per_name(body.grep(BelongsTo))
            end

            def has_many
              last_per_name(body.grep(HasMany))
            end

            def before_validation_callbacks
              body.grep(BeforeValidation).flat_map(&:names)
            end

            def includes
              body.grep(Include).map(&:name)
            end

            # The `belongs_to` on this model whose target is `owner_class` — the
            # inverse the association-construction path sets (`record.post =
            # owner`). nil when no belongs_to points back at the owner.
            def inverse_belongs_to_for(owner_class)
              belongs_to.find { |b| b.class_name == owner_class }
            end

            private

            # Keeps the LAST declaration of each name, at its own position.
            def last_per_name(assocs)
              assocs.reverse.uniq(&:name).reverse
            end
          end

          # Parses a model source into `ModelReflections` (one per class AND per
          # module in the file). Returns [] when the file declares nothing the
          # generator cares about.
          #
          # A module is scanned because an Active Record association just as
          # often comes from a concern as from the model's own body
          # (`has_many :notifications` inside `User::Notifiable`); its entries
          # are spliced into each includer by `ConcernResolver`, which is the
          # side that can see across files.
          module ReflectionScanner
            module_function

            def scan(path:, source:)
              result = Prism.parse(source)
              return [] unless result.success?

              RbsInfer::Analyzer.find_all_nodes(result.value) do |n|
                n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)
              end.filter_map { |node| reflections_for(path, node) }
            end

            def reflections_for(path, node)
              class_name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)&.delete_prefix("::")
              return nil unless class_name

              is_class = node.is_a?(Prism::ClassNode)
              body = is_class ? class_body(node) : concern_body(node)

              # A CLASS is kept even when it declares nothing, because the set of
              # scanned classes is also the ORACLE the element resolver consults:
              # `has_many :data_exports, class_name: "User::DataExport"` is only
              # modelable if `User::DataExport` is in it, and that model declares
              # no association of its own (felixefelip/rbs_infer#141). It still
              # produces no reopen — the builder emits for what needs one.
              #
              # A concern that declares nothing has nothing to splice, and is not
              # a model, so it is dropped here.
              return nil if !is_class && body.empty?

              ModelReflections.new(
                path: path,
                class_name: class_name,
                kind: is_class ? :class : :module,
                body: body
              )
            end

            # Entries from receiverless macro calls at class-body level (a call
            # nested in a def or an unrelated block is not the AR class macro).
            def class_body(klass)
              statements(klass.body).flat_map { |stmt| entries_for(stmt) }
            end

            # A concern contributes its `included do … end` macros — which Rails
            # runs against the includer — plus any module-level `include`, which
            # ActiveSupport::Concern propagates to the includer as well. Its
            # plain method defs are just methods, reachable as self-sends.
            def concern_body(mod)
              statements(mod.body).flat_map do |stmt|
                next [] unless stmt.is_a?(Prism::CallNode)
                next entries_for(stmt) unless stmt.name == :included && stmt.block

                statements(stmt.block.body).flat_map { |inner| entries_for(inner) }
              end
            end

            def entries_for(stmt)
              return [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.arguments

              case stmt.name
              when :belongs_to
                name = first_symbol(stmt) or return []
                [BelongsTo.new(
                  name: name,
                  class_name: belongs_to_class(name, stmt),
                  default_body: default_expr_source(stmt)
                )]
              when :has_many
                name = first_symbol(stmt) or return []
                [HasMany.new(
                  name: name,
                  class_name: has_many_class(name, stmt),
                  through: symbol_kwarg(stmt, "through"),
                  source: symbol_kwarg(stmt, "source")
                )]
              when :before_validation
                names = symbol_args(stmt)
                names.empty? ? [] : [BeforeValidation.new(names: names)]
              when :include
                constant_args(stmt).map { |const| Include.new(name: const) }
              else
                []
              end
            end

            def statements(body)
              case body
              when Prism::StatementsNode then body.body
              when nil then []
              else [body]
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

            # `include Post::Taggable` → ["Post::Taggable"]. A non-constant
            # argument (`include Module.new { … }`) names nothing to splice.
            def constant_args(call)
              call.arguments.arguments.filter_map do |arg|
                next unless arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)

                RbsInfer::Analyzer.extract_constant_path(arg)&.delete_prefix("::")
              end
            end

            def belongs_to_class(name, call)
              string_kwarg(call, "class_name") || name.camelize
            end

            # The source of a `default: -> { expr }` lambda's single-expression
            # body (`"post.user"`), for the AR-runtime generator to reopen as a
            # real before_validation method (`self.<assoc> ||= post.user`) that
            # the contract machinery can narrow (felixefelip/rbs_infer#XXX).
            # nil unless `default:` is a one-expression lambda.
            def default_expr_source(call)
              hash = call.arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
              return nil unless hash

              assoc = hash.elements.find do |elem|
                elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode) && elem.key.value.to_s == "default"
              end
              return nil unless assoc

              node = assoc.value
              return nil unless node.is_a?(Prism::LambdaNode)

              body = node.body
              return nil unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

              body.body.first.slice
            end

            def has_many_class(name, call)
              string_kwarg(call, "class_name") || name.singularize.camelize
            end

            def string_kwarg(call, key)
              node = kwarg(call, key)
              node.is_a?(Prism::StringNode) ? node.unescaped : nil
            end

            # `through: :boards` -> "boards". A non-literal (`source: SOURCE`)
            # names nothing this scan can follow.
            def symbol_kwarg(call, key)
              node = kwarg(call, key)
              node.is_a?(Prism::SymbolNode) ? node.value.to_s : nil
            end

            def kwarg(call, key)
              hash = call.arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
              return nil unless hash

              assoc = hash.elements.find do |elem|
                elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode) && elem.key.value.to_s == key
              end
              assoc&.value
            end
          end
        end
      end
    end
  end
end
