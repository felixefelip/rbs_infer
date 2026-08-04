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
    def apply(target_source, detect_source:, path:, module_name:, mixin_index: nil)
      return target_source if module_name.nil? || module_name.empty?

      @annotators.each do |annotator|
        entries_from(annotator, path: path, module_name: module_name,
                                source: detect_source, mixin_index: mixin_index).each do |entry|
          target_source = Steep::Source::ModuleSelfTypes.inject(
            target_source, annotations: entry["annotations"], anchor: entry["anchor"]
          )
        end
      end
      target_source
    end

    INSTANCE_ANNOTATION = /\A#\s*@type\s+instance:\s*(?<type>.+?)\s*\z/

    # The type a module's INSTANCE methods see as `self`, or nil when no
    # annotator covers the file. Same plugins and same entries `apply` injects,
    # READ instead of injected — a file being scanned for call sites is parsed
    # as it is on disk, so the annotation is never there, yet its `self` still
    # has to resolve to something (felixefelip/rbs_infer#161).
    #
    # Matched on the anchor, so a file declaring more than one module cannot
    # borrow a sibling's answer.
    #
    # Returned PARENTHESIZED, which the annotation is not: an intersection is
    # only legal bare in argument position. Measured — `(A & B x) -> void`
    # parses, `() -> A & B` is a syntax error — and it is the same shape the
    # callback sidecar already stores (`(::Post & ::Post::Validated)`), so a
    # type that reaches a return is usable wherever it lands.
    def instance_type(path:, module_name:, source:, mixin_index: nil)
      return nil if module_name.nil? || module_name.empty?

      anchor = module_name.split("::").last

      type = @annotators.filter_map do |annotator|
        entries_from(annotator, path: path, module_name: module_name, source: source, mixin_index: mixin_index)
          .select { |entry| entry["anchor"] == anchor }
          .flat_map { |entry| entry["annotations"] }
          .filter_map { |line| line[INSTANCE_ANNOTATION, :type] }
          .first
      end.first

      "(#{type})" if type
    end

    # `{ "Card::Stallable" => "(Card & Card::Stallable)" }` for the modules a file
    # declares — what `self` is in each of them, which is what a call site inside a
    # concern passes when it writes `Detector.new(self)`.
    #
    # One place, because two of them ask: the caller-file walk and the resolver's
    # own walks over the same files. Answering it in only one of them is how
    # `Card::ActivitySpike::Detector#initialize` came out `untyped` while the
    # sidecar had the answer all along (felixefelip/rbs_infer#175).
    def instance_types(path:, module_names:, source:, mixin_index:)
      module_names.to_h do |name|
        [name, instance_type(path: path, module_name: name, source: source, mixin_index: mixin_index)]
      end.compact
    end

    # `mixin_index` is passed only to annotators that ask for it, so adding it
    # to the contract does not break one written against the older three
    # (felixefelip/rbs_infer#163).
    def entries_from(annotator, path:, module_name:, source:, mixin_index:)
      if accepts_mixin_index?(annotator)
        annotator.self_type_entries(path: path, module_name: module_name, source: source, mixin_index: mixin_index)
      else
        annotator.self_type_entries(path: path, module_name: module_name, source: source)
      end
    end

    def accepts_mixin_index?(annotator)
      annotator.method(:self_type_entries).parameters.any? do |kind, name|
        name == :mixin_index || kind == :keyrest
      end
    end
  end
end
