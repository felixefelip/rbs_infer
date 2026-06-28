# frozen_string_literal: true

require "prism"
require "yaml"
require "fileutils"

module RbsInfer
  module Extensions
    module Rails
      # Emits `sig/generated/.steep_module_self_types.yml` — the sidecar that
      # Steep's `Steep::Source::ModuleSelfTypes` reads to inject
      # `@type self:`/`@type instance:` into concerns/modules during parsing
      # (felixefelip/rbs_infer#52).
      #
      # For each module/concern under the covered roots it records, keyed by the
      # project-relative path, the leaf-name anchor and the annotation lines —
      # computed by `ModuleSelfTypeAnnotator` from the AST-derived FQN (correct
      # acronym casing) and Rails conventions. This replaces the path-based name
      # derivation that used to live in Steep.
      class ModuleSelfTypeGenerator
        SIDECAR_PATH = "sig/generated/.steep_module_self_types.yml"
        ROOTS = %w[app/models app/helpers app/controllers/concerns].freeze

        def initialize(app_dir:)
          @app_dir = app_dir
        end

        # Builds the path → entry table. Public so the CLI can write it without
        # touching disk conventions twice.
        def build_table
          table = {}
          ROOTS.each do |root|
            Dir.glob(File.join(@app_dir, root, "**/*.rb")).sort.each do |abs|
              rel = relative(abs)
              entry = entry_for_file(abs, rel)
              table[rel] = entry if entry
            end
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
          extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: abs)
          Prism.parse(source).value.accept(extractor)
          module_name = extractor.class_name
          return nil unless module_name

          ModuleSelfTypeAnnotator.entry_for(path: rel, module_name: module_name, source: source)
        rescue StandardError
          nil
        end

        def relative(abs)
          prefix = "#{@app_dir.chomp('/')}/"
          abs.start_with?(prefix) ? abs[prefix.length..] : abs
        end
      end
    end
  end
end
