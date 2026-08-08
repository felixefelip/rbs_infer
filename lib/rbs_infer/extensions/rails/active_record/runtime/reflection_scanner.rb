# frozen_string_literal: true

require "prism"
require "set"
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

          # A `scope :name, -> { … }`. Only the NAME is kept: rbs_rails already
          # types scopes (it reflects `klass.scope_definitions` at runtime and
          # writes them into `<Model>::GeneratedRelationMethods`), so this entry
          # exists solely to keep the class-method delegation from emitting the
          # same name into the same module — a `DuplicateMethodDefinition` poisons
          # the whole RBS environment, not just the one file.
          Scope = Struct.new(:name, keyword_init: true)

          # A concern's `ClassMethods` module — written literally, or desugared
          # from `class_methods do … end`. ActiveSupport::Concern extends it into
          # the includer's singleton, so the includer's relation delegates to it
          # exactly like to a `def self.x`.
          #
          # It is carried as the MODULE rather than as its individual methods
          # because the includer's own RBS does not re-declare them: nothing
          # emits the `extend <Concern>::ClassMethods` that Concern performs at
          # include time, so `Post.default_tag_names` does not resolve and a
          # delegation through it would not type. Including the module into
          # `GeneratedRelationMethods` states the same fact one level up, where
          # the signatures already exist.
          ClassMethodsModule = Struct.new(:name, keyword_init: true)

          # One `store_accessor` key: the reader/writer pair Active Record defines
          # with `define_method` inside `_store_accessors_module` — an anonymous
          # module it INCLUDES into the model, which is what lets an override
          # written in the class body call `super`. None of it is statically
          # visible, so without the pseudo-code the accessor does not exist for
          # the checker at all: every read is a `NoMethod`, not an `untyped`.
          #
          # `key` is the store slot and `name` the method actually defined, which
          # `prefix:`/`suffix:` change while the slot does not — so two macros
          # naming one slot differently share the storage they share at runtime.
          StoreAccessor = Struct.new(:store, :key, :name, keyword_init: true)

          # A public CLASS method written as `def self.x` / inside `class << self`.
          # Active Record delegates these to relations and collection proxies
          # (`ActiveRecord::Delegation::ClassSpecificRelation#method_missing`
          # compiles `def x(...) = scoping { model.x(...) }` into the per-model
          # `GeneratedRelationMethods` module), which is what makes
          # `user.posts.from_params(…)` a real call (felixefelip/rbs_infer#185).
          #
          # `params` is the parameter list AS WRITTEN and `args` the matching
          # forwarding list, so the emitted delegation keeps the method's arity
          # and each parameter is inferred from the real call sites.
          SingletonMethod = Struct.new(:name, :params, :args, keyword_init: true)

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
            :superclass, # "ApplicationRecord" (nil for a module, or a bare class)
            :body,       # [BelongsTo | HasMany | BeforeValidation | Include | Scope |
                         #  SingletonMethod | ClassMethodsModule | StoreAccessor]
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

            # The class methods to delegate to the relation, minus any name
            # rbs_rails already wrote into the same module as a scope.
            def delegatable_singleton_methods
              scoped = body.grep(Scope).map(&:name).to_set
              last_per_name(body.grep(SingletonMethod)).reject { |m| scoped.include?(m.name) }
            end

            # The `ClassMethods` modules the included concerns contribute, in
            # include order and without repeats.
            def class_methods_modules
              body.grep(ClassMethodsModule).map(&:name).uniq
            end

            # The store accessors, keeping the LAST declaration of each METHOD
            # name: re-declaring a key redefines the pair, and two entries under
            # one name would emit a `DuplicateMethodDefinition` into the module —
            # which poisons the whole RBS environment, not just this file.
            def store_accessors
              last_per_name(body.grep(StoreAccessor))
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
              body = is_class ? class_body(node) : concern_body(node, class_name)

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
                superclass: is_class ? RbsInfer::Analyzer.extract_constant_path(node.superclass)&.delete_prefix("::") : nil,
                body: body
              )
            end

            # Entries from receiverless macro calls at class-body level (a call
            # nested in a def or an unrelated block is not the AR class macro),
            # plus the class methods written directly in the body. The singleton
            # methods are appended rather than interleaved: nothing about them is
            # order-sensitive, and the macro order is what the concern splice
            # depends on.
            def class_body(klass)
              stmts = statements(klass.body)
              stmts.flat_map { |stmt| entries_for(stmt) } + singleton_method_entries(stmts)
            end

            # A concern contributes its `included do … end` macros — which Rails
            # runs against the includer — plus any module-level `include`, which
            # ActiveSupport::Concern propagates to the includer as well. Its
            # plain method defs are just methods, reachable as self-sends.
            def concern_body(mod, module_name)
              statements(mod.body).flat_map do |stmt|
                # `module ClassMethods … end` written out — the same thing
                # `class_methods do` desugars to, and just as common.
                if stmt.is_a?(Prism::ModuleNode)
                  next class_methods_module(stmt, module_name)
                end
                next [] unless stmt.is_a?(Prism::CallNode)

                case stmt.name
                when :included
                  next entries_for(stmt) unless stmt.block

                  statements(stmt.block.body).flat_map { |inner| entries_for(inner) }
                when :class_methods
                  stmt.block ? [ClassMethodsModule.new(name: "#{module_name}::ClassMethods")] : []
                else
                  entries_for(stmt)
                end
              end
            end

            def class_methods_module(node, module_name)
              name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
              return [] unless name == "ClassMethods"

              [ClassMethodsModule.new(name: "#{module_name}::ClassMethods")]
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
              when :scope
                name = first_symbol(stmt) or return []
                [Scope.new(name: name)]
              when :store_accessor
                store_accessor_entries(stmt)
              when :store
                store_entries(stmt)
              when :include
                constant_args(stmt).map { |const| Include.new(name: const) }
              else
                []
              end
            end

            # --- store accessors ----------------------------------------------

            # `store_accessor :settings, :theme, :channel, prefix: true` — one
            # entry per key. The first symbol names the store column and the rest
            # are keys; the trailing kwargs hash is skipped by `symbol_list`.
            def store_accessor_entries(call)
              args = call.arguments.arguments
              store = args.first.is_a?(Prism::SymbolNode) ? args.first.value.to_s : nil
              return [] unless store

              store_accessors_for(call, store, symbol_list(args.drop(1)))
            end

            # `store :settings, accessors: [ :theme ], coder: JSON` — the same
            # pairs, from the macro that also declares the serialization. Without
            # `accessors:` it defines no method at all (`store :request, coder:
            # JSON`), so there is nothing to model.
            def store_entries(call)
              store = first_symbol(call) or return []

              store_accessors_for(call, store, symbol_list([kwarg(call, "accessors")].compact))
            end

            def store_accessors_for(call, store, keys)
              prefix = affix(call, "prefix", store)
              suffix = affix(call, "suffix", store)

              keys.map do |key|
                StoreAccessor.new(store: store, key: key, name: "#{prefix}#{key}#{suffix}")
              end
            end

            # Active Record builds the method name as `"#{prefix}#{key}#{suffix}"`,
            # where `true` means "use the store's own name" and a symbol/string
            # means that name. The separating `_` belongs to the affix, so a key
            # with neither is untouched.
            def affix(call, position, store)
              node = kwarg(call, position)
              value =
                case node
                when Prism::TrueNode then store
                when Prism::SymbolNode then node.value.to_s
                when Prism::StringNode then node.unescaped
                else return ""
                end

              position == "prefix" ? "#{value}_" : "_#{value}"
            end

            # Symbols, plus the contents of any array literal among them: Active
            # Record flattens `keys`, so `store_accessor :settings, %i[a b]` is
            # the same declaration as spelling them out.
            def symbol_list(nodes)
              nodes.flat_map do |node|
                case node
                when Prism::SymbolNode then [node.value.to_s]
                when Prism::ArrayNode then symbol_list(node.elements)
                else []
                end
              end
            end

            # --- class methods ------------------------------------------------

            # The public class methods a class body declares, both spellings:
            # `def self.x` and a `class << self` block. `private_class_method
            # def self.x` is excluded for free — the def is the CALL's argument,
            # not a statement of the body — and the symbol form is subtracted.
            def singleton_method_entries(stmts)
              private_names = private_class_method_names(stmts)

              nodes = stmts.flat_map do |stmt|
                case stmt
                when Prism::DefNode
                  stmt.receiver.is_a?(Prism::SelfNode) ? [stmt] : []
                when Prism::SingletonClassNode
                  stmt.expression.is_a?(Prism::SelfNode) ? public_defs(statements(stmt.body)) : []
                else
                  []
                end
              end

              nodes.reject { |node| private_names.include?(node.name.to_s) }
                .map { |node| singleton_method(node) }
            end

            # The receiverless defs of a `class << self` / `class_methods do`
            # body, stopping at a bare `private` — Rails delegates only PUBLIC
            # class methods (`method_missing` guards on `model.respond_to?`).
            def public_defs(stmts)
              visible = true

              stmts.filter_map do |stmt|
                if stmt.is_a?(Prism::CallNode) && stmt.name == :private && stmt.receiver.nil? && stmt.arguments.nil?
                  visible = false
                  nil
                elsif stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && visible
                  stmt
                end
              end
            end

            def private_class_method_names(stmts)
              stmts.grep(Prism::CallNode)
                .select { |call| call.name == :private_class_method && call.receiver.nil? && call.arguments }
                .flat_map { |call| symbol_args(call) }
                .to_set
            end

            # The delegation's parameter list and matching forwarding list. Both
            # come from the parameters AS WRITTEN, so arity survives and each
            # parameter is inferred from the call sites — except where copying
            # them would not be sound (see `forwardable_params?`), where the
            # anonymous `(*, **, &)` of the real `method_missing` is used instead.
            def singleton_method(node)
              params = node.parameters

              if forwardable_params?(params)
                SingletonMethod.new(name: node.name.to_s, params: params&.slice.to_s, args: forwarding_args(params))
              else
                SingletonMethod.new(name: node.name.to_s, params: ANONYMOUS_PARAMS, args: ANONYMOUS_PARAMS)
              end
            end

            # Matches Active Record's own `def x(...) = scoping { model.x(...) }`
            # in arity terms while staying spellable in the pseudo-code.
            ANONYMOUS_PARAMS = "*, **, &"

            # A default value is copied VERBATIM into the reopened module, whose
            # lexical scope is `<Model>::GeneratedRelationMethods` — not the
            # model's — so a default naming a constant the model owns
            # (`def self.page(size = PER_PAGE)`) would not resolve there. Only
            # self-contained literals are copied; anything else (and `...`, which
            # has no forwarding spelling the pipeline reads) falls back to the
            # anonymous list. Destructuring parameters have no name to forward.
            LITERAL_DEFAULTS = [
              Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
              Prism::TrueNode, Prism::FalseNode, Prism::NilNode
            ].freeze

            def forwardable_params?(params)
              return true if params.nil?
              return false if params.keyword_rest.is_a?(Prism::ForwardingParameterNode)
              return false unless (params.requireds + params.posts).all?(Prism::RequiredParameterNode)

              (params.optionals + params.keywords.grep(Prism::OptionalKeywordParameterNode))
                .all? { |opt| LITERAL_DEFAULTS.any? { |type| opt.value.is_a?(type) } }
            end

            def forwarding_args(params)
              return "" if params.nil?

              parts = (params.requireds + params.optionals).map { |p| p.name.to_s }
              parts << (params.rest.name ? "*#{params.rest.name}" : "*") if params.rest.is_a?(Prism::RestParameterNode)
              parts.concat(params.posts.map { |p| p.name.to_s })
              parts.concat(params.keywords.map { |k| "#{k.name}: #{k.name}" })
              if params.keyword_rest.is_a?(Prism::KeywordRestParameterNode)
                parts << (params.keyword_rest.name ? "**#{params.keyword_rest.name}" : "**")
              end
              parts << (params.block.name ? "&#{params.block.name}" : "&") if params.block

              parts.join(", ")
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
