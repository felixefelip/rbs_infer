# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

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
            end

            # Returns [FileEntry], or [] when nothing qualifies (no model has a
            # `before_validation` callback nor a has_many to a known model).
            def build
              class_reopens + proxy_reopens
            end

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
            #                 getters: [{ name:, proxy:, element: }, ...] }
            def reopen_plan
              plan = Hash.new { |h, k| h[k] = { callbacks: [], belongs_to_defaults: [], getters: [] } }

              @models.each do |model|
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
                  element = @by_class[assoc.class_name]
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
              defaults = info[:belongs_to_defaults]
              if info[:callbacks].any? || defaults.any?
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
            # without one (e.g. a `has_many :through`), only owner capture is
            # emitted and construction is inherited from the real proxy.
            def proxy_reopens
              seen = {}
              @models.flat_map do |owner|
                owner.has_many.filter_map do |assoc|
                  element = @by_class[assoc.class_name]
                  next unless element

                  ns = proxy_namespace(owner.class_name, element.class_name)
                  next if seen[ns]

                  seen[ns] = true
                  inverse = element.inverse_belongs_to_for(owner.class_name)
                  FileEntry.new(filename: "#{file_name(ns)}.rb", source: proxy_source(ns, element.class_name, inverse))
                end
              end
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
