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
      # Two sidecars, mirroring the `.steep_module_self_types.yml` precedent:
      #
      #   * EXPANDED_PATH — the synthetic `.rb` program Steep adds to its
      #     check targets.
      #   * SIDECAR_PATH — the YAML source-map: for each covered `default:`
      #     lambda, the line in the expansion that stands in for it, so Steep
      #     (#54) remaps any expansion diagnostic to the real span AND
      #     suppresses its native check of that span (now covered here).
      class BelongsToDefaultGenerator
        SIDECAR_PATH = "sig/generated/.steep_belongs_to_default.yml"
        EXPANDED_PATH = "sig/generated/.steep_belongs_to_default.rb"

        # Roots scanned for models (reflections) and for construction sites.
        MODEL_ROOTS = %w[app/models].freeze
        CALLER_ROOTS = %w[app/controllers app/models app/services].freeze

        def initialize(app_dir:)
          @app_dir = app_dir
        end

        # Builds the ExpansionBuilder::Result (expanded source + source map),
        # or nil when no model declares a `belongs_to ..., default:`. Public so
        # the CLI/specs can inspect the expansion without touching disk.
        def build
          models = scan_models
          defaulted = models.select { |m| m.default_associations.any? }
          return nil if defaulted.empty?

          sites = scan_construction_sites(models)
          BelongsToDefault::ExpansionBuilder.new(models: defaulted, all_models: models, sites: sites).build
        end

        # Writes both sidecars (removing stale ones when nothing qualifies, so
        # a deleted `default:` doesn't linger). Returns [expanded_path,
        # sidecar_path].
        def generate
          result = build
          expanded_out = File.join(@app_dir, EXPANDED_PATH)
          sidecar_out = File.join(@app_dir, SIDECAR_PATH)

          if result.nil?
            FileUtils.rm_f(expanded_out)
            FileUtils.rm_f(sidecar_out)
          else
            FileUtils.mkdir_p(File.dirname(expanded_out))
            File.write(expanded_out, result.expanded_source)
            File.write(sidecar_out, YAML.dump(result.source_map))
          end

          [expanded_out, sidecar_out]
        end

        private

        def scan_models
          each_rb(MODEL_ROOTS).filter_map do |abs, rel|
            BelongsToDefault::ReflectionScanner.scan(path: rel, source: File.read(abs))
          rescue StandardError
            nil
          end.flatten
        end

        def scan_construction_sites(models)
          index = BelongsToDefault::AssociationIndex.new(models)
          return [] unless index.any?

          each_rb(CALLER_ROOTS).flat_map do |abs, rel|
            BelongsToDefault::ConstructionSiteScanner.scan(path: rel, source: File.read(abs), index: index)
          rescue StandardError
            []
          end
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
