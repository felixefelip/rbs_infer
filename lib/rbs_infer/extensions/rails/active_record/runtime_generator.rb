# frozen_string_literal: true

require "fileutils"
require_relative "runtime/reflection_scanner"
require_relative "runtime/pseudo_code_builder"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        # Emits the Forma-2 "AR runtime" pseudo-code sidecar
        # (felixefelip/rbs_infer#72): a directory of `.rb` reopens that model
        # Active Record's construction + save flow for the real classes, so the
        # Steep fork can narrow `self.<belongs_to>` inside `before_validation`
        # callbacks by pure inference (plus inferred pre/postconditions), rather
        # than a hand-written contract.
        #
        # Depends on `felixefelip/rbs_rails` emitting the owner-specific
        # association proxy (`<Owner>_<Element>::ActiveRecord_Associations_CollectionProxy`
        # with a typed `owner`); this reopens that proxy with the construction
        # body. Consumed by the Steep fork; the generation itself is verifiable
        # standalone (model → pseudo-code).
        #
        # Scope (Forma 2, step 1): `before_validation :method` callbacks and the
        # atomic `create`/`create!` path. The `belongs_to default:` inlining and
        # the split `build` + later `save` case are follow-ups.
        class RuntimeGenerator
          # NOT dot-prefixed: these are `.rb` SOURCE files Steep must type-check
          # (via a `check "sig/**/*.rb"` glob), and `**` skips hidden (dot)
          # directories — a dot-prefixed dir would be invisible to Steep. (The
          # `.steep_*.yml` sidecars can be dot-prefixed because the fork loads
          # them explicitly, not through a source glob.)
          SIDECAR_DIR = "sig/generated/steep_ar_runtime"
          MODEL_ROOTS = %w[app/models].freeze

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # Returns [Runtime::PseudoCodeBuilder::FileEntry] (empty when no model
          # registers a `before_validation` callback). Public so the CLI/specs
          # can inspect the pseudo-code without touching disk.
          def build
            models = scan_models
            Runtime::PseudoCodeBuilder.new(models: models).build
          end

          # Writes the sidecar directory (one file per reopened class), removing
          # a stale dir when nothing qualifies. Returns the sidecar dir path.
          def generate
            files = build
            dir = File.join(@app_dir, SIDECAR_DIR)

            FileUtils.rm_rf(dir)
            unless files.empty?
              FileUtils.mkdir_p(dir)
              files.each { |file| File.write(File.join(dir, file.filename), file.source) }
            end

            dir
          end

          private

          def scan_models
            MODEL_ROOTS.flat_map do |root|
              Dir.glob(File.join(@app_dir, root, "**/*.rb")).sort.flat_map do |abs|
                Runtime::ReflectionScanner.scan(path: relative(abs), source: File.read(abs))
              rescue StandardError => e
                warn "[rbs_infer ar_runtime] skipped #{relative(abs)}: #{e.class}: #{e.message}"
                []
              end
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
