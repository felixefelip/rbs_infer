# frozen_string_literal: true

require "fileutils"
require_relative "pseudo_code_builder"

module RbsInfer
  module Extensions
    module Rails
      module Views
        # Emits the view-runtime pseudo-code sidecar: one plain `.rb` per ERB template, from
        # which the analyzer infers the view's RBS.
        #
        # Sibling of `Controllers::RuntimeGenerator`, and the same idea — model at the source
        # level what the framework does at runtime, then let the ordinary pipeline read it —
        # applied to ActionView instead of ActionController. See Views::PseudoCodeBuilder for
        # why this replaces the hand-derived types `ErbConventionGenerator` emitted.
        class RuntimeGenerator
          # NOT dot-prefixed: these are `.rb` SOURCE files Steep must type-check (via a
          # `check "sig/**/*.rb"` glob), and `**` skips hidden (dot) directories.
          SIDECAR_DIR = "sig/generated/steep_actionview_runtime"

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # Returns [PseudoCodeBuilder::FileEntry]. Public so the CLI/specs can inspect the
          # pseudo-code without touching disk.
          def build
            PseudoCodeBuilder.new(app_dir: @app_dir).build
          end

          # Writes the sidecar directory, removing a stale one when nothing qualifies.
          # Returns the sidecar dir path.
          def generate
            files = build
            dir = File.join(@app_dir, SIDECAR_DIR)

            FileUtils.rm_rf(dir)
            unless files.empty?
              files.each do |file|
                path = File.join(dir, file.filename)
                FileUtils.mkdir_p(File.dirname(path))
                File.write(path, file.source)
              end
            end

            dir
          end
        end
      end
    end
  end
end
