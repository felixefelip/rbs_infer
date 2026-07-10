# frozen_string_literal: true

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
          #     stub — and the base for the `Owner` / `Owner & Owner::Validated`
          #     variation once the proxy is made generic over the owner);
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
            # `before_validation` callback).
            def build
              class_reopens + proxy_reopens
            end

            private

            # --- class reopens (owner getters + model save flow, merged) -----

            # One reopen per class that needs either a save flow (it registers
            # `before_validation` callbacks) or a `has_many` getter (it owns an
            # association whose element has such callbacks). Both are merged into
            # a single `<Class>.rb` when a class is both.
            def class_reopens
              plan = reopen_plan
              plan.map do |class_name, info|
                FileEntry.new(filename: "#{flat(class_name)}.rb", source: class_source(class_name, info))
              end
            end

            # class_name => { callbacks: [...], getters: [{ name:, proxy:, element: }, ...] }
            def reopen_plan
              plan = Hash.new { |h, k| h[k] = { callbacks: [], getters: [] } }

              @models.each do |model|
                plan[model.class_name][:callbacks] = model.before_validation_callbacks if model.before_validation_callbacks.any?

                model.has_many.each do |assoc|
                  element = @by_class[assoc.class_name]
                  next unless element && element.before_validation_callbacks.any?
                  next unless element.inverse_belongs_to_for(model.class_name)

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
              if info[:callbacks].any?
                # `save(**)` matches the real `save: (?context:, ?validate:,
                # ?touch:) -> bool`; it runs the before_validation callbacks so
                # their nilable-belongs_to deref is reachable from `save`.
                body.concat(method_lines("save", "**") { ["run_before_validation_callbacks", "true"] })
                body << ""
                body.concat(method_lines("run_before_validation_callbacks") { info[:callbacks] })
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

            # A proxy reopen per (owner has_many element) where the element has
            # before_validation callbacks. Deduplicated by proxy namespace.
            def proxy_reopens
              seen = {}
              @models.flat_map do |owner|
                owner.has_many.filter_map do |assoc|
                  element = @by_class[assoc.class_name]
                  next unless element && element.before_validation_callbacks.any?

                  ns = proxy_namespace(owner.class_name, element.class_name)
                  next if seen[ns]

                  inverse = element.inverse_belongs_to_for(owner.class_name)
                  next unless inverse

                  seen[ns] = true
                  FileEntry.new(filename: "#{ns}.rb", source: proxy_source(ns, element, inverse))
                end
              end
            end

            def proxy_source(ns, element, inverse)
              record = element.class_name
              body = []
              # `initialize(klass, owner)` matches the real constructor arity
              # `(untyped, untyped)`; `owner` returns the captured owner (its
              # type comes from rbs_rails' `owner: () -> Owner`).
              body.concat(method_lines("initialize", "klass, owner") { ["@owner = owner"] })
              body << ""
              body.concat(method_lines("owner") { ["@owner"] })
              body << ""
              body.concat(method_lines("build", "*") do
                ["record = #{record}.new", "record.#{inverse.name} = owner", "record"]
              end)
              body << ""
              # `create`/`create!` = build + save. `build` is called with NO
              # args so it matches the optional-arg overload of the RBS `build`.
              body.concat(method_lines("create", "*") do
                ["record = build", "record.save", "record"]
              end)
              body << ""
              body.concat(method_lines("create!", "*") do
                ["record = build", "record.save", "record"]
              end)

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
          end
        end
      end
    end
  end
end
