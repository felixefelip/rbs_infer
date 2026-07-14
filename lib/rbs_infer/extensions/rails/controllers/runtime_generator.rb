# frozen_string_literal: true

require "fileutils"
require_relative "callback_chain_scanner"
require_relative "pseudo_code_builder"

module RbsInfer
  module Extensions
    module Rails
      module Controllers
        # Emits the controller-runtime pseudo-code sidecar
        # (felixefelip/rbs_infer#81): plain Ruby reopens that model the request
        # flow of every action — its effective `before_action` chain, then the
        # action — so the Steep fork can prove by inference what the action may
        # assume on entry (`@post` populated by `set_post`; `Current.user`
        # present past a halting guard), instead of consuming hand-derived
        # facts through a sidecar YAML.
        #
        # The proof itself is the fork's job and needs felixefelip/steep#68
        # (ivar effects across calls, path-sensitive exit state, constant-rooted
        # contracts). This generator owns only the pseudo-code.
        class RuntimeGenerator
          # NOT dot-prefixed: these are `.rb` SOURCE files Steep must type-check
          # (via a `check "sig/**/*.rb"` glob), and `**` skips hidden (dot)
          # directories — a dot-prefixed dir would be invisible to Steep.
          SIDECAR_DIR = "sig/generated/steep_controller_runtime"

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # Returns [PseudoCodeBuilder::FileEntry] (empty when the app has no
          # controller with actions). Public so the CLI/specs can inspect the
          # pseudo-code without touching disk.
          def build
            PseudoCodeBuilder.new(scanner: CallbackChainScanner.new(app_dir: @app_dir)).build
          end

          # Writes the sidecar directory (one .rb/.rbs pair per controller, plus
          # the framework reopen), removing a stale dir when nothing qualifies.
          # Returns the sidecar dir path.
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
        end
      end
    end
  end
end
