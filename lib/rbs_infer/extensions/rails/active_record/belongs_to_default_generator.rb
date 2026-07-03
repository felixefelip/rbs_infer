# frozen_string_literal: true

require "prism"
require "yaml"
require "fileutils"
require "active_support/core_ext/string/inflections"
require_relative "belongs_to_default/reflection_scanner"
require_relative "belongs_to_default/construction_site_scanner"
require_relative "belongs_to_default/expansion_builder"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        # Desugars `belongs_to :x, default: -> { post.user }` (plus the
        # association-construction call-sites that build the record) into an
        # `example.rb`-shaped, self-contained plain-Ruby program that Steep
        # type-checks by pure inference — plus a source-map linking the
        # expansion back to the real `default:` lambda
        # (felixefelip/rbs_infer#72, consumed by felixefelip/steep#54).
        #
        # Why this is NOT a `SourceExpander` (the CurrentAttributes path):
        # a SourceExpander desugars for rbs_infer's OWN inference — its output
        # is never seen by the app's `steep check`. Here the generated RBS is
        # already correct (`post: Post?`); the false positive is Steep's check
        # of the REAL `default:` lambda:
        #
        #   app/models/assignment.rb:19: Type `(::Post | nil)` does not have method `user`
        #
        # Runtime never raises: an `Assignment` is only ever built through
        # `post.assignments` (which sets `post`), and `default:` runs in
        # `before_validation`. So the fix must be CONSUMED by Steep, via a
        # sidecar Steep checks and maps back — not fed to rbs_infer's parse.
        #
        # The emitted program reproduces the proven `example.rb` contract shape
        # (felixefelip/steep#51 explicit-receiver + attribute-write narrowing,
        # #52 transitive closure): the model side inlines the lambda body into a
        # lifecycle-callback method reachable from `save`, and each caller
        # establishes the derefed `belongs_to` before `save`. Steep infers the
        # precondition (`save` requires `self.post`) and enforces it — so:
        #
        #   * a caller that establishes `post` (via the association owner) ⇒ no
        #     error ⇒ the native `default:` diagnostic is suppressed (correct);
        #   * an `Assignment.new.save` that does NOT establish `post` ⇒ the
        #     expansion errors ⇒ mapped back to the real lambda (sound — the
        #     false positive is removed only where construction proves `post`).
        #
        # The sidecar is a directory + a source-map, mirroring the
        # `.steep_module_self_types.yml` precedent:
        #
        #   * EXPANDED_DIR — one synthetic `.rb` per class, added by Steep to
        #     its check targets.
        #   * SIDECAR_PATH — the YAML source-map: for each covered `default:`
        #     lambda, the expansion file + line that stand in for it, so Steep
        #     (#54) remaps any expansion diagnostic to the real span AND
        #     suppresses its native check of that span (now covered here).
        class BelongsToDefaultGenerator
          SIDECAR_PATH = "sig/generated/.steep_belongs_to_default.yml"
          EXPANDED_DIR = "sig/generated/.steep_belongs_to_default"

          # Roots scanned for models (reflections) and for construction sites.
          MODEL_ROOTS = %w[app/models].freeze
          CALLER_ROOTS = %w[app/controllers app/models app/services].freeze

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # Builds the ExpansionBuilder::Result (per-class files + source map),
          # or nil when no model declares a `belongs_to ..., default:`. Public
          # so the CLI/specs can inspect the expansion without touching disk.
          def build
            models = scan_models
            defaulted = models.select { |m| m.default_associations.any? }
            return nil if defaulted.empty?

            sites = scan_construction_sites(models)
            BelongsToDefault::ExpansionBuilder.new(models: defaulted, all_models: models, sites: sites).build
          end

          # Writes the expansion directory (one file per class) + the source-map
          # sidecar, removing stale output when nothing qualifies so a deleted
          # `default:` doesn't linger. Returns [expanded_dir, sidecar_path].
          def generate
            result = build
            expanded_dir = File.join(@app_dir, EXPANDED_DIR)
            sidecar_out = File.join(@app_dir, SIDECAR_PATH)

            FileUtils.rm_rf(expanded_dir)
            if result.nil?
              FileUtils.rm_f(sidecar_out)
            else
              FileUtils.mkdir_p(expanded_dir)
              result.files.each { |file| File.write(File.join(expanded_dir, file.filename), file.source) }
              File.write(sidecar_out, YAML.dump(result.source_map))
            end

            [expanded_dir, sidecar_out]
          end

          private

          def scan_models
            each_rb(MODEL_ROOTS).flat_map do |abs, rel|
              BelongsToDefault::ReflectionScanner.scan(path: rel, source: File.read(abs))
            rescue StandardError => e
              warn_skip(rel, e)
              []
            end
          end

          def scan_construction_sites(models)
            index = BelongsToDefault::AssociationIndex.new(models)
            return [] unless index.any?

            each_rb(CALLER_ROOTS).flat_map do |abs, rel|
              BelongsToDefault::ConstructionSiteScanner.scan(path: rel, source: File.read(abs), index: index)
            rescue StandardError => e
              warn_skip(rel, e)
              []
            end
          end

          # A malformed/unreadable file is skipped rather than aborting the whole
          # run, but the skip is announced (not silently swallowed) so a real bug
          # is visible instead of degrading into "the feature just didn't fire".
          def warn_skip(rel, error)
            warn "[rbs_infer belongs_to_default] skipped #{rel}: #{error.class}: #{error.message}"
          end

          def each_rb(roots)
            roots.flat_map do |root|
              Dir.glob(File.join(@app_dir, root, "**/*.rb")).sort.map { |abs| [abs, relative(abs)] }
            end
          end

          def relative(abs)
            prefix = "#{@app_dir.chomp('/')}/"
            abs.start_with?(prefix) ? abs[prefix.length..] : abs
          end
        end
      end
    end
  end
end
