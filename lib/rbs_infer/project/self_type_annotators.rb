# frozen_string_literal: true

require "steep/source/module_self_types"

module RbsInfer::Project
  # Registry of plugins that inject `@type self:` / `@type instance:`
  # annotations into the target file's source BEFORE the parse, so the
  # pipeline (and Steep, as the return-type oracle) sees the right self-type
  # for concerns/modules and their desugared submodules
  # (felixefelip/rbs_infer#52, #60).
  #
  # Sibling to `SourceExpanders`: both rewrite the in-memory source before the
  # parse, and the core knows none of them — extensions (from this gem or third
  # parties) register at require time. Annotator contract:
  #
  #   annotator.self_type_entries(path:, module_name:, source:)
  #     #=> Array[{ "anchor" => String, "annotations" => Array[String] }]
  #
  # Each entry is placed by Steep's generic `Source::ModuleSelfTypes.inject`
  # (the same mechanism the downstream `.steep_module_self_types.yml` uses);
  # the annotator owns only the *what* (which module, which `@type` lines),
  # never the *how*. Annotators must be cheap on the no-op path (gate on a
  # substring / convention before parsing) and return `[]` when nothing applies.
  #
  # Detection runs against the *original* (pre-expansion) source, while the
  # entries are injected into the post-expansion `target_source`. That split
  # lets an annotator key on a macro the expanders have already desugared away
  # (e.g. `class_methods do`, gone once it becomes `module ClassMethods`) yet
  # still anchor the annotation onto the desugared submodule.
  module SelfTypeAnnotators
    @annotators = []

    module_function

    def register(annotator)
      @annotators << annotator unless @annotators.include?(annotator)
      annotator
    end

    def unregister(annotator)
      @annotators.delete(annotator)
    end

    def annotators
      @annotators.dup
    end

    # Injects every registered annotator's entries into `target_source` and
    # returns the annotated source. `detect_source` is what annotators inspect
    # (the original file); `target_source` is what gets parsed (post-expansion).
    # A no-op (no annotators, no matches) returns `target_source` unchanged.
    def apply(target_source, detect_source:, path:, module_name:)
      return target_source if module_name.nil? || module_name.empty?

      @annotators.each do |annotator|
        annotator.self_type_entries(path: path, module_name: module_name, source: detect_source).each do |entry|
          target_source = Steep::Source::ModuleSelfTypes.inject(
            target_source, annotations: entry["annotations"], anchor: entry["anchor"]
          )
        end
      end
      target_source
    end
  end
end
