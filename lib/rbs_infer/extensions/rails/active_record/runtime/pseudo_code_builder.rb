# frozen_string_literal: true

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module Runtime
          # Builds the Forma-2 "AR runtime" pseudo-code: it REOPENS the real
          # classes (the model and the owner-specific association proxy that
          # rbs_rails declares) and gives them the construction + save flow that
          # models what Active Record does at runtime, so Steep — reading plain
          # Ruby — can narrow `self.<belongs_to>` inside a `before_validation`
          # callback (felixefelip/rbs_infer#72, Forma 2).
          #
          # Two reopens per case:
          #
          #   * the MODEL — `save` runs the `before_validation` callbacks (the
          #     real callback methods, only CALLED here), so the deref of a
          #     nilable belongs_to inside them becomes reachable from `save`;
          #   * the owner-specific PROXY — `build` establishes the inverse
          #     belongs_to from the association `owner` (rbs_rails types it), and
          #     `create`/`create!` = build + save.
          #
          # rbs_rails owns the TYPES (the proxy class + `owner`); this only adds
          # the plain-Ruby bodies. The Steep fork infers the precondition on
          # `save` and (for the split build/save case) the postcondition on
          # `build` from these bodies — no hand-written contract sidecar.
          class PseudoCodeBuilder
            # One emitted file: `filename` within the sidecar dir; `source` is
            # the standalone reopen.
            FileEntry = Struct.new(:filename, :source, keyword_init: true)

            # models: every scanned ModelReflections (used to resolve has_many
            #   elements and find their before_validation callbacks).
            def initialize(models:)
              @models = models
              @by_class = models.to_h { |m| [m.class_name, m] }
            end

            # Returns [FileEntry], or [] when nothing qualifies (no model has a
            # `before_validation` callback).
            def build
              files = []
              files.concat(model_reopens)
              files.concat(proxy_reopens)
              files
            end

            private

            # A model reopen per model that registers `before_validation`
            # callbacks — the save flow that makes those callbacks reachable.
            def model_reopens
              @models.select { |m| m.before_validation_callbacks.any? }.map do |model|
                FileEntry.new(filename: "#{flat(model.class_name)}.rb", source: model_source(model))
              end
            end

            def model_source(model)
              lines = ["class #{model.class_name}"]
              lines.concat(method_lines("save") { ["run_before_validation_callbacks", "true"] })
              lines << ""
              lines.concat(method_lines("run_before_validation_callbacks") do
                model.before_validation_callbacks
              end)
              lines << "end"
              file(lines)
            end

            # A proxy reopen per (owner has_many element) where the element has
            # before_validation callbacks — the construction flow. Deduplicated
            # by proxy namespace (a rarer two-associations-to-one-element case
            # shares one proxy, mirroring rbs_rails).
            def proxy_reopens
              seen = {}
              @models.flat_map do |owner|
                owner.has_many.filter_map do |assoc|
                  element = @by_class[assoc.class_name]
                  next unless element && element.before_validation_callbacks.any?

                  ns = proxy_namespace(owner.class_name, element.class_name)
                  next if seen[ns]

                  seen[ns] = true
                  inverse = element.inverse_belongs_to_for(owner.class_name)
                  next unless inverse

                  FileEntry.new(filename: "#{ns}.rb", source: proxy_source(ns, element, inverse))
                end
              end
            end

            def proxy_source(ns, element, inverse)
              record = element.class_name
              lines = ["class #{ns}::ActiveRecord_Associations_CollectionProxy"]
              lines.concat(method_lines("build", "attributes = nil") do
                ["record = #{record}.new", "record.#{inverse.name} = owner", "record"]
              end)
              lines << ""
              lines.concat(method_lines("new", "attributes = nil") { ["build(attributes)"] })
              lines << ""
              lines.concat(method_lines("create", "attributes = nil") do
                ["record = build(attributes)", "record.save", "record"]
              end)
              lines << ""
              lines.concat(method_lines("create!", "attributes = nil") do
                ["record = build(attributes)", "record.save", "record"]
              end)
              lines << "end"
              file(lines)
            end

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
            # namespace (`felixefelip/rbs_rails` owner-association-proxy). `::`
            # in a namespaced class is flattened to `_`.
            def proxy_namespace(owner_class, element_class)
              "#{flat(owner_class)}_#{flat(element_class)}"
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
