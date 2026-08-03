# frozen_string_literal: true

require "prism"
require "yaml"
require "fileutils"
require_relative "class_methods_implements"
# The whole gem, not a leaf: this generator now reads the `include`s through
# `Project::MixinIndex`, which walks sources with the analyzer's own helpers.
# `rbs_infer.rb` does not load this file, so there is no cycle.
require "rbs_infer"

module RbsInfer
  module Extensions
    module Rails
      # Emits `sig/generated/.steep_module_self_types.yml` — the sidecar that
      # Steep's `Steep::Source::ModuleSelfTypes` reads to inject
      # `@type self:`/`@type instance:` into concerns/modules during parsing
      # (felixefelip/rbs_infer#52).
      #
      # Keyed by project-relative path, it records one entry per MODULE the file
      # declares — the leaf-name anchor and the annotation lines, computed by
      # `ModuleSelfTypeAnnotator` from the AST-derived FQN (correct acronym
      # casing) and from who includes it. This replaces the path-based name
      # derivation that used to live in Steep.
      #
      # It also records, in the same entry, the `blocks` that Steep should
      # annotate with `# @implements` — currently a concern's `class_methods do`
      # block, resolved by `ClassMethodsImplements` (felixefelip/rbs_infer#60,
      # felixefelip/steep#47). A file can produce a `blocks`-only entry even
      # when it has no self-type annotations.
      class ModuleSelfTypeGenerator
        SIDECAR_PATH = "sig/generated/.steep_module_self_types.yml"

        # Every Ruby source the project checks, `sig/` included: a module's self
        # type is not a property of where its file sits, and the transcription
        # of a framework mixin lives under `sig/generated/`
        # (felixefelip/rbs_infer#165).
        SOURCE_GLOBS = ["app/**/*.rb", "sig/**/*.rb"].freeze

        def initialize(app_dir:)
          @app_dir = app_dir
        end

        # Builds the path → entry table. Public so the CLI can write it without
        # touching disk conventions twice.
        def build_table
          table = {}
          # Built here rather than lazily inside `entry_for_file`, whose
          # `rescue StandardError` would turn a broken index into an empty
          # table — and an empty table DELETES the sidecar, silently.
          mixin_index

          source_files.each do |abs|
            rel = relative(abs)
            entry = entry_for_file(abs, rel)
            table[rel] = entry if entry
          end
          table
        end

        # Writes the sidecar (removing a stale one when nothing qualifies, so a
        # deleted concern doesn't linger). Returns the absolute sidecar path.
        def generate
          table = build_table
          out = File.join(@app_dir, SIDECAR_PATH)
          if table.empty?
            FileUtils.rm_f(out)
          else
            FileUtils.mkdir_p(File.dirname(out))
            File.write(out, YAML.dump(table))
          end
          out
        end

        private

        def entry_for_file(abs, rel)
          source = File.read(abs)
          tree = Prism.parse(source).value

          entry = {}
          modules = self_types_for(rel, source, tree)
          entry["modules"] = modules if modules.any?

          blocks = blocks_for(abs, rel, source)
          entry["blocks"] = blocks if blocks.any?

          entry.empty? ? nil : entry
        rescue StandardError
          nil
        end

        # One per module the file DECLARES, not one for the file. A concern is
        # one module in one file and reads the same either way; a framework
        # transcription reopens several, and the name that stands for the file
        # is the outermost wrapper — which nobody includes, and whose self type
        # is nothing (felixefelip/rbs_infer#165).
        def self_types_for(rel, source, tree)
          RbsInfer::Inference::NewCallCollector.collect_defined_class_names(tree).sort.filter_map do |name|
            ModuleSelfTypeAnnotator.entry_for(path: rel, module_name: name, source: source,
                                              mixin_index: mixin_index)
          end
        end

        # Still keyed on the file's own name: a `class_methods do` block belongs
        # to the concern the file is written for.
        def blocks_for(abs, rel, source)
          extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: abs)
          Prism.parse(source).value.accept(extractor)
          module_name = extractor.class_name
          return [] unless module_name

          ClassMethodsImplements.blocks_for(path: rel, module_name: module_name, source: source,
                                            mixin_index: mixin_index)
        end

        # The `include`s written across the app, so a module's self-type comes
        # from what the code says rather than from where its file sits
        # (felixefelip/rbs_infer#163).
        #
        # The same sources the table is built from, so this sidecar and the
        # in-process annotation read one project and cannot disagree.
        def mixin_index
          @mixin_index ||= RbsInfer::Project::MixinIndex.new(source_files)
        end

        def source_files
          @source_files ||= SOURCE_GLOBS.flat_map { |glob| Dir.glob(File.join(@app_dir, glob)) }.sort
        end

        def relative(abs)
          prefix = "#{@app_dir.chomp('/')}/"
          abs.start_with?(prefix) ? abs[prefix.length..] : abs
        end
      end
    end
  end
end
