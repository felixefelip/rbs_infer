# frozen_string_literal: true

require "set"
require "active_support/core_ext/string/inflections"
require_relative "../../../../ast/lexical_constant_resolver"
require_relative "reflection_scanner"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module Runtime
          # Builds the Forma-2 "AR runtime" pseudo-code: it REOPENS the real
          # classes (the model, the owner, and the owner-specific association
          # proxy that rbs_rails declares) and gives them the construction +
          # save flow that models what Active Record does at runtime, so Steep —
          # reading plain Ruby — can narrow `self.<belongs_to>` inside a
          # `before_validation` callback (felixefelip/rbs_infer#72, Forma 2).
          #
          # Reopens:
          #
          #   * the MODEL — `save` runs the `before_validation` callbacks (the
          #     real callback methods, only CALLED here), so the deref of a
          #     nilable belongs_to inside them becomes reachable from `save`;
          #   * the OWNER — the `has_many` getter returns `Proxy.new(self)`, so
          #     the association `owner`'s type flows from `self` (inferred, not a
          #     stub). Capturing `owner` from the caller's `self` is the base for
          #     refining it to `Owner & Owner::Validated` at a call site —
          #     reachable via the Steep fork's contract machinery
          #     (constructor-binding + return forwarding);
          #   * the owner-specific PROXY — `initialize(owner)` captures it,
          #     `owner` returns it; `build` establishes the inverse belongs_to
          #     from `owner`, and `create`/`create!` = build + save.
          #
          # rbs_rails owns the TYPES (the proxy class, the getter's return, the
          # `owner`); this only adds the plain-Ruby bodies. The Steep fork infers
          # the precondition on `save` and (for the split build/save case) the
          # postcondition on `build` from these bodies — no hand-written contract.
          class PseudoCodeBuilder
            # One emitted file: `filename` within the sidecar dir; `source` is
            # the standalone reopen.
            FileEntry = Struct.new(:filename, :source, keyword_init: true)

            def initialize(models:)
              @models = models
              @by_class = models.to_h { |m| [m.class_name, m] }
              @elements = {}
            end

            # Returns [FileEntry], or [] when nothing qualifies (no model has a
            # `before_validation` callback nor a has_many to a known model).
            def build
              class_reopens + proxy_reopens + relation_method_reopens + store_accessor_reopens
            end

            # The module Active Record's `store_accessor` builds at runtime.
            # `Generated…` matches the neighbourhood rbs_rails already owns
            # (`GeneratedAttributeMethods`, `GeneratedRelationMethods`) and keeps
            # the name clear of anything an app would write itself — AR's own is
            # anonymous, so there is no real name to match.
            STORE_ACCESSORS_MODULE = "GeneratedStoreAccessors"

            private

            # --- class reopens (owner getters + model save flow, merged) -----

            # One reopen per class that needs either a save flow (it registers
            # `before_validation` callbacks) or a `has_many` getter (it owns a
            # has_many association to a known model). Both are merged into a
            # single `<Class>.rb` when a class is both.
            def class_reopens
              plan = reopen_plan
              plan.map do |class_name, info|
                FileEntry.new(filename: "#{file_name(class_name)}.rb", source: class_source(class_name, info))
              end
            end

            # class_name => { callbacks: [...], belongs_to_defaults: [BelongsTo],
            #                 getters: [{ name:, proxy:, element: }, ...],
            #                 store_accessors: bool }
            def reopen_plan
              plan = Hash.new do |h, k|
                h[k] = { callbacks: [], belongs_to_defaults: [], getters: [], store_accessors: false }
              end

              @models.each do |model|
                plan[model.class_name][:store_accessors] = true if model.store_accessors.any?

                plan[model.class_name][:callbacks] = model.before_validation_callbacks if model.before_validation_callbacks.any?

                # A `belongs_to ... default: -> { expr }` runs `expr` in a
                # before_validation callback with `self` = the record, so its
                # nilable-belongs_to deref becomes reachable from `save` — the
                # same flow as a named callback.
                defaults = model.belongs_to.select(&:default_body)
                plan[model.class_name][:belongs_to_defaults] = defaults if defaults.any?

                model.has_many.each do |assoc|
                  # Emit a getter for EVERY has_many whose element is a known
                  # model — rbs_infer owns the getter now (rbs_rails stopped
                  # emitting it), so `owner.<assoc>` types via this pseudo-code.
                  # An element outside the scanned models can't be modeled
                  # (its class/proxy may not exist), so it's skipped.
                  element = element_for(model, assoc)
                  next unless element

                  plan[model.class_name][:getters] << {
                    name: assoc.name,
                    proxy: proxy_type(model.class_name, element.class_name),
                    element: element.class_name
                  }
                end
              end

              plan
            end

            def class_source(class_name, info)
              body = []
              # `store_accessor` defines the pair inside a module it INCLUDES, not
              # in the class — which is exactly what lets an override in the class
              # body call `super`. Emitting the pair as plain `def`s here would
              # both lose that and collide with the override.
              body << "  include ::#{class_name}::#{STORE_ACCESSORS_MODULE}" if info[:store_accessors]

              defaults = info[:belongs_to_defaults]
              if info[:callbacks].any? || defaults.any?
                body << "" unless body.empty?

                # `save(**)` matches the real `save: (?context:, ?validate:,
                # ?touch:) -> bool`; it runs the before_validation callbacks (the
                # named ones and the belongs_to `default:` lambdas) so their
                # nilable-belongs_to deref is reachable from `save`.
                rbvc = info[:callbacks].dup
                rbvc << "run_belongs_to_default_callbacks" if defaults.any?

                body.concat(method_lines("save", "**") { ["run_before_validation_callbacks", "true"] })
                body << ""
                body.concat(method_lines("run_before_validation_callbacks") { rbvc })

                if defaults.any?
                  # `default: -> { expr }` sets the association if unset, so
                  # `self.<assoc> ||= expr` models `writer(...) if reader.nil?`;
                  # `expr`'s deref (`post.user`) narrows once `save` enforces the
                  # inferred precondition, exactly like a named callback.
                  body << ""
                  body.concat(method_lines("run_belongs_to_default_callbacks") do
                    defaults.map { |b| "run_belongs_to_default_#{b.name}" }
                  end)
                  defaults.each do |b|
                    body << ""
                    body.concat(method_lines("run_belongs_to_default_#{b.name}") do
                      ["self.#{b.name} ||= #{b.default_body}"]
                    end)
                  end
                end
              end
              info[:getters].each do |getter|
                body << "" unless body.empty?
                # Two args to match the real CollectionProxy constructor
                # `(untyped, untyped)`; `self` is captured as the owner.
                body.concat(method_lines(getter[:name]) { ["#{getter[:proxy]}.new(#{getter[:element]}, self)"] })
              end

              file(["class #{class_name}", *body, "end"])
            end

            # --- proxy reopens -----------------------------------------------

            # A proxy reopen per (owner has_many element) to a known model,
            # deduplicated by proxy namespace. Captures the owner (`initialize`/
            # `owner`) so rbs_infer types `owner` from the getter call-site.
            # When the element has an inverse belongs_to back at the owner, the
            # proxy also gets the construction flow (`build`/`create`/`create!`);
            # without one, only owner capture is emitted and construction is
            # inherited from the real proxy.
            def proxy_reopens
              proxy_plan.map do |ns, info|
                FileEntry.new(filename: "#{file_name(ns)}.rb", source: proxy_source(ns, info[:element], info[:inverse]))
              end
            end

            # ns => { element:, inverse: }.
            #
            # The namespace is per (owner, ELEMENT) pair, so several associations
            # can land on the same one — `comments` and `accessible_comments` are
            # both User -> Comment. The candidate that models construction wins
            # whatever the declaration order is: a concern's `include` sits above
            # the class's own macros, so `accessible_comments` is reached first,
            # and taking the first would strip `user.comments.create` of its
            # construction flow.
            def proxy_plan
              plan = {}

              @models.each do |owner|
                owner.has_many.each do |assoc|
                  element = element_for(owner, assoc)
                  next unless element

                  ns = proxy_namespace(owner.class_name, element.class_name)
                  inverse = inverse_for(owner, assoc, element)
                  plan[ns] = { element: element.class_name, inverse: inverse } if inverse || !plan.key?(ns)
                end
              end

              plan
            end

            # The belongs_to that `build` establishes from the owner — none for a
            # `through:` association: Active Record builds the element WITHOUT
            # pointing it back at the owner there (`user.accessible_cards.build`
            # leaves `creator` unset, since the row that links them lives on the
            # join). Emitting `record.creator = owner` would hand the contract
            # machinery a fact the runtime never establishes.
            def inverse_for(owner, assoc, element)
              element.inverse_belongs_to_for(owner.class_name) unless assoc.through
            end

            def proxy_source(ns, element_class, inverse)
              body = []
              # `initialize(klass, owner)` matches the real constructor arity
              # `(untyped, untyped)`; `owner` returns the captured owner (whose
              # type rbs_infer infers from the getter's `self`).
              body.concat(method_lines("initialize", "klass, owner") { ["@owner = owner"] })
              body << ""
              body.concat(method_lines("owner") { ["@owner"] })

              if inverse
                body << ""
                body.concat(method_lines("build", "*") do
                  ["record = #{element_class}.new", "record.#{inverse.name} = owner", "record"]
                end)
                body << ""
                # `create` = build + save. `build` is called with NO args so it
                # matches the optional-arg overload of the RBS `build`.
                body.concat(method_lines("create", "*") do
                  ["record = build", "record.save", "record"]
                end)
                body << ""
                # `create!` = `create or raise` — it delegates to `create`
                # rather than repeating `build`/`save`. Emitting both
                # independently forks the single `record.save` call site across
                # two callers; when only one (`create!`) is reachable, the other
                # (`create`) is dead but still counted, and — being statically
                # indistinguishable from a framework entrypoint — cannot be
                # discounted, so a precondition on `save` never enforces
                # (felixefelip/steep#65). Delegating keeps the `save` site single
                # and the caller chain linear (`save` <- `create` <- `create!`),
                # so the reachable path alone decides enforcement. The `or raise`
                # models the bang method's failure semantics (create! raises
                # rather than returning a falsy record).
                body.concat(method_lines("create!", "*") { ["create or raise ActiveRecord::RecordInvalid"] })
              end

              file(["class #{ns}::ActiveRecord_Associations_CollectionProxy", *body, "end"])
            end

            # --- relation class-method reopens --------------------------------

            # Active Record delegates a model's public CLASS methods to its
            # relations and collection proxies: `Relation#method_missing`
            # (activerecord's `relation/delegation.rb`) compiles
            # `def x(...) = scoping { model.x(...) }` into the per-model
            # `GeneratedRelationMethods` module the first time such a call is
            # made. Nothing emitted that statically — rbs_rails writes only the
            # `scope`/`enum` macros into that module (it reflects at runtime and
            # has no type for a hand-written `def self.x`), and rbs_infer typed
            # the method on the class SINGLETON alone — so
            # `user.filters.from_params(…)` was a NoMethodError on the proxy
            # (felixefelip/rbs_infer#185).
            #
            # `<Model>::GeneratedRelationMethods` is the one place all of them
            # see: it is the constant Active Record itself const_sets, and
            # rbs_rails already includes it into `ActiveRecord_Relation` AND into
            # the collection proxy every owner-specific proxy descends from. One
            # reopen therefore reaches the relation, the per-element proxy and
            # every per-owner proxy — and keeps a SINGLE call site per delegated
            # method, which repeating the body per proxy would fork (the reason
            # `create!` delegates to `create` above).
            #
            # Emitted as plain Ruby rather than as a copy of the model's
            # signature, so the return type comes from the pipeline and each
            # parameter is inferred from the real call sites.
            def relation_method_reopens
              @models.filter_map do |model|
                next unless active_record?(model)

                methods = model.delegatable_singleton_methods
                modules = model.class_methods_modules
                next if methods.empty? && modules.empty?

                # Under a directory named for the model, so the sidecar's flat
                # list stays one file per reopened CLASS and everything else a
                # model needs has an obvious home next to this one.
                FileEntry.new(
                  filename: "#{file_name(model.class_name)}/generated_relation_methods.rb",
                  source: relation_methods_source(model.class_name, methods, modules)
                )
              end
            end

            # Every constant is written ABSOLUTE. The reopen sits inside the
            # model's own namespace, where a relative name is resolved against it
            # first: `include Storage::Totaled::ClassMethods` inside
            # `class Account` means `::Account::Storage::Totaled::ClassMethods`
            # once `Account::Storage` exists — which it does, and RBS then failed
            # with `Cannot find type Storage::Totaled::ClassMethods`
            # (felixefelip/rbs_infer#185). Nothing here is ever meant to resolve
            # relatively: the names come from a whole-project scan, already full.
            def relation_methods_source(class_name, methods, modules)
              body = modules.map { |mod| "  include ::#{mod}" }
              methods.each do |method|
                body << "" unless body.empty?
                params = method.params.empty? ? nil : method.params
                receiver = "::#{class_name}.#{method.name}"
                call = method.args.empty? ? receiver : "#{receiver}(#{method.args})"
                body.concat(method_lines(method.name, params) { [call] })
              end

              file(["module #{class_name}::GeneratedRelationMethods", *body, "end"])
            end

            # `GeneratedRelationMethods` is an Active Record concept: it exists
            # only for a model, so a plain class under `app/models` (a service
            # object, a `CurrentAttributes` subclass) must not get one. The
            # superclass chain — resolved through the scanned classes, so an STI
            # child counts through its parent — is what says which is which.
            def active_record?(model, seen = Set.new)
              parent = model.superclass
              return false unless parent && seen.add?(model.class_name)
              return true if parent.delete_prefix("::") == "ActiveRecord::Base"

              found = resolve_constant(parent, model.class_name)
              found ? active_record?(found, seen) : false
            end

            # --- store accessor reopens --------------------------------------

            # One module per model declaring `store_accessor`, holding the
            # reader/writer pair for each key. `class_source` emits the matching
            # `include`, so a model that needs nothing else still gets its reopen.
            #
            # Nothing here states a type — same rule as the Devise generator. The
            # slot is an ivar assigned only by the writer, so the pipeline reads
            # the writer's parameter off its real call sites and the "assigned
            # outside `initialize`" rule makes the reader nilable on its own,
            # which is what a store key that was never written actually is.
            # Modelling the read as `settings["theme"]` instead would be faithful
            # and permanently `untyped`: the column is json.
            def store_accessor_reopens
              @models.filter_map do |model|
                accessors = model.store_accessors
                next if accessors.empty?

                FileEntry.new(
                  filename: "#{file_name(model.class_name)}/#{file_name(STORE_ACCESSORS_MODULE)}.rb",
                  source: store_accessors_source(model.class_name, accessors)
                )
              end
            end

            def store_accessors_source(class_name, accessors)
              body = []
              accessors.each do |accessor|
                ivar = store_ivar(accessor)
                body << "" unless body.empty?
                body.concat(method_lines(accessor.name) { [ivar] })
                body << ""
                body.concat(method_lines("#{accessor.name}=", "value") { ["#{ivar} = value"] })
              end

              file(["module #{class_name}::#{STORE_ACCESSORS_MODULE}", *body, "end"])
            end

            # The slot the pair reads and writes, named after the store COLUMN and
            # the key rather than the method: `prefix:`/`suffix:` variants of one
            # key then share the storage they share at runtime, and the `__store_`
            # namespace keeps a key from ever colliding with an ivar the model
            # assigns itself.
            def store_ivar(accessor)
              "@__store_#{accessor.store}_#{accessor.key}"
            end

            # NOTE: the synthetic `run_before_validation_callbacks` is defined in
            # the emitted `.rb` (see `class_source`); rbs_infer infers its RBS
            # from that pseudo-code, so this generator no longer hand-writes a
            # `<Model>.rbs` for it. A hand-written declaration would collide with
            # the inferred one (DuplicateMethodDefinition).

            # --- emit helpers ------------------------------------------------

            def method_lines(name, params = nil)
              sig = params ? "def #{name}(#{params})" : "def #{name}"
              ["  #{sig}", *yield.map { |l| "    #{l}" }, "  end"]
            end

            def file(lines)
              header = [
                "# frozen_string_literal: true",
                "#",
                "# GENERATED by RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator.",
                "# Regenerated on every run; do not edit.",
                ""
              ]
              "#{(header + lines).join("\n")}\n"
            end

            # --- element resolution ------------------------------------------

            # The model a `has_many`'s elements are, resolved the way Active
            # Record resolves it: by walking the `through:` chain when there is
            # one, and otherwise from the written (or conventional) class name.
            # nil when the element is outside the scanned models — neither its
            # class nor its proxy would exist, so it cannot be modeled.
            #
            # Deriving it from the ASSOCIATION NAME alone dropped every through
            # association whose name is not the element's: `has_many
            # :accessible_cards, through: :boards, source: :cards` guessed
            # `AccessibleCard`, found no such model, and emitted neither the
            # getter nor the proxy — `user.accessible_cards` had no type at all
            # (felixefelip/rbs_infer#141).
            def element_for(owner, assoc, seen = Set.new)
              key = [owner.class_name, assoc.name]
              return @elements[key] if @elements.key?(key)
              return nil unless seen.add?(key)

              @elements[key] =
                if assoc.through
                  # `class_name:` is not what names a through association's
                  # element (Active Record takes it from the source reflection),
                  # so the chain decides. The conventional name is the fallback
                  # for a `through:` this scan cannot follow — a `has_one`, or an
                  # association declared in a gem.
                  through_element(owner, assoc, seen) || resolve_constant(assoc.class_name, owner.class_name)
                else
                  resolve_constant(assoc.class_name, owner.class_name)
                end
            end

            # `has_many :accessible_cards, through: :boards, source: :cards` is
            # `Card`: hop to the owner's `boards` — itself possibly a through,
            # hence the recursion, since `accessible_comments` goes through
            # `accessible_cards` — then read `cards` off THAT model, which is
            # where the element's name (and any `class_name:` on it) lives.
            def through_element(owner, assoc, seen)
              hop = association_named(owner, assoc.through)
              return nil unless hop

              hop_model = association_element(owner, hop, seen)
              return nil unless hop_model

              source = source_association(hop_model, assoc)
              source && association_element(hop_model, source, seen)
            end

            # The source reflection Active Record looks for: the `source:` name
            # when given, and otherwise the association's own name in singular
            # then plural. `has_many :assignees, through: :assignments` reads
            # `assignee` off `Assignment` — which is where `class_name: "User"`
            # is written, and why guessing from `assignees` cannot work.
            def source_association(hop_model, assoc)
              names = assoc.source ? [assoc.source] : [assoc.name.singularize, assoc.name].uniq
              names.filter_map { |name| association_named(hop_model, name) }.first
            end

            def association_named(model, name)
              model.has_many.find { |a| a.name == name } || model.belongs_to.find { |b| b.name == name }
            end

            # A hop lands on a model either through a collection — recursing,
            # since a `through:` can chain — or through a `belongs_to`, which
            # names its element directly.
            def association_element(owner, assoc, seen)
              case assoc
              when HasMany then element_for(owner, assoc, seen)
              when BelongsTo then resolve_constant(assoc.class_name, owner.class_name)
              end
            end

            # The model a written constant names, resolved the way Ruby (and therefore
            # `ActiveRecord::Base.compute_type`) resolves it: from the owner's
            # namespace outward. `has_many :recomendacao_vacinas` inside `Caderneta` is
            # `Caderneta::RecomendacaoVacina` when that exists, and only then the top-level
            # `RecomendacaoVacina` (felixefelip/rbs_infer#128).
            #
            # Matching on the bare `classify` alone silently dropped the association: the
            # element was not among the scanned models under that name, so neither the
            # reader nor the proxy reopen was emitted, and `caderneta.recomendacao_vacinas`
            # had no type at all. The walk itself lives in `LexicalConstantResolver` —
            # shared with every other site that turns a written constant into a class
            # (felixefelip/rbs_infer#129); the scanned-model table is the oracle.
            def resolve_constant(element_class, owner_class)
              found = RbsInfer::AST::LexicalConstantResolver.resolve(
                name: element_class, enclosing: owner_class
              ) { |candidate| @by_class.key?(candidate) }

              found && @by_class[found]
            end

            # `<Owner>_<Element>` — matches rbs_rails' owner-specific proxy
            # namespace. `::` in a namespaced class is flattened to `_`.
            def proxy_namespace(owner_class, element_class)
              "#{flat(owner_class)}_#{flat(element_class)}"
            end

            def proxy_type(owner_class, element_class)
              "#{proxy_namespace(owner_class, element_class)}::ActiveRecord_Associations_CollectionProxy"
            end

            def flat(class_name)
              class_name.gsub("::", "_")
            end

            # The snake_case file name for a reopened constant, for visual
            # uniformity with the rest of `sig/`. Only the FILE name is snaked —
            # the reopened constant itself keeps its real casing (via `flat` /
            # `proxy_namespace`), since it must be valid Ruby and match the
            # rbs_rails namespace (`Post_Assignment`, not `post_assignment`).
            def file_name(constant)
              constant.underscore.gsub("/", "_")
            end
          end
        end
      end
    end
  end
end
