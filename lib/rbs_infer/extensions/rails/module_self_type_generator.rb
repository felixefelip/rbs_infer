# frozen_string_literal: true

require "prism"
require "yaml"
require "fileutils"
require_relative "class_methods_implements"
# The whole gem, not a leaf: this generator now reads the `include`s through
# `Project::MixinIndex`, which walks sources with the analyzer's own helpers.
# `rbs_infer.rb` does not load this file, so there is no cycle.
require "rbs_infer"
require "steep"

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

        STEEPFILE = "Steepfile"

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
                                              mixin_index: mixin_index,
                                              invoker_self_types: invoker_self_types)
          end
        end

        # Two contributors, one list. A stored block replayed through
        # `class_eval` is plain Ruby, so its entries come from the CORE
        # (`Project::StoredBlockReplayImplements`) and need no name for the
        # file: the target is read off the replay chain, not off the file's own
        # module (felixefelip/rbs_infer#238).
        #
        # The `class_methods do` half is still keyed on the file's own name — a
        # `class_methods do` block belongs to the concern the file is written
        # for — so it is the only half that needs the extractor, and a file with
        # no primary declaration can still contribute the first half.
        def blocks_for(abs, rel, source)
          RbsInfer::Project::StoredBlockReplayImplements.blocks_for(source: source, sources: constant_sources) +
            class_methods_blocks_for(abs, rel, source)
        end

        def class_methods_blocks_for(abs, rel, source)
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

        # Where a DSL's own methods are declared, over the SAME files again — a
        # replay's target must be the one the expander moves the block to, and
        # two readers looking at different projects could not guarantee that
        # (felixefelip/rbs_infer#238).
        def constant_sources
          @constant_sources ||= RbsInfer::Project::Corpus.for(declared_files).constant_sources
        end

        # The files the project DECLARES, which is not the list of files it
        # type-checks. A Steepfile `ignore` says "report no diagnostics here",
        # not "this file is not part of the program" — and a framework-patching
        # file is exactly the shape that gets ignored while still declaring the
        # DSL a checked file calls (`lib/rails_ext/**` in the dummy, and #38's
        # reason for ignoring it: stock Steep cannot impl-check a raw
        # `on_load` reopening).
        #
        # Reading the narrow list here would let this sidecar resolve fewer
        # replays than the expander does, and the two disagreeing about which
        # class a block defines its methods on is the one thing
        # `StoredBlockReplayImplements` exists to prevent.
        def declared_files
          @declared_files ||= steep_targets.flat_map { |target| paths_in(target, ignores: false) }
                                           .select { |path| path.extname == ".rb" }
                                           .uniq.sort
                                           .map { |path| File.join(@app_dir, path) }
        end

        # Narrows a module method's `self` to the hosts that call it
        # (felixefelip/rbs_infer#222), over the SAME files as the index above —
        # this sidecar and the in-process annotation read one project and
        # cannot disagree.
        def invoker_self_types
          @invoker_self_types ||= RbsInfer::Inference::InvokerSelfTypes.new(
            source_index: RbsInfer::Project::SourceIndex.new(source_files),
            parse_cache: RbsInfer::Project::ParseCache.new
          )
        end

        # Exactly what the project tells Steep to check, `ignore`s included —
        # asked of the Steepfile rather than guessed from a list of directories.
        # A module's self type is not a property of where its file sits, and the
        # transcription of a framework mixin lives under `sig/generated/`
        # (felixefelip/rbs_infer#165).
        #
        # No Steepfile, no files: this sidecar exists for `steep check` and for
        # nothing else, so a project that does not run it has nothing to write.
        def source_files
          @source_files ||= steep_targets.flat_map { |target| paths_in(target) }
                                         .select { |path| path.extname == ".rb" }
                                         .uniq.sort
                                         .map { |path| File.join(@app_dir, path) }
        end

        def steep_targets
          path = Pathname(File.join(@app_dir, STEEPFILE))
          return [] unless path.file?

          project = Steep::Project.new(steepfile_path: path.expand_path)
          Steep::Project::DSL.parse(project, path.read)
          project.targets
        rescue StandardError
          []
        end

        def paths_in(target, ignores: true)
          pattern = target.source_pattern
          unless ignores
            pattern = Steep::Project::Pattern.new(patterns: pattern.patterns, ext: pattern.ext, ignores: [])
          end

          Steep::Services::FileLoader.new(base_dir: Pathname(@app_dir))
                                     .each_path_in_patterns(pattern).to_a
        end

        def relative(abs)
          prefix = "#{@app_dir.chomp('/')}/"
          abs.start_with?(prefix) ? abs[prefix.length..] : abs
        end
      end
    end
  end
end
