# frozen_string_literal: true

require "fileutils"
require_relative "callback_chain_scanner"
require_relative "pseudo_code_builder"
require_relative "framework_source_transcriber"

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

          # `transcribe_framework:` asks for the framework's own source to be
          # transcribed alongside the app's flow (felixefelip/rbs_infer#144). It
          # is a PARAMETER rather than something detected, because detecting it
          # means reflecting on loaded constants — and then the sidecar's content
          # would depend on whether something in the process happened to require
          # Rails, which is environment rather than intent. The rake task, which
          # runs inside the booted app, asks for it; a bare library call does not.
          def initialize(app_dir:, transcribe_framework: false)
            @app_dir = app_dir
            @transcribe_framework = transcribe_framework
          end

          # Returns [PseudoCodeBuilder::FileEntry] (empty when the app has no
          # controller with actions). Public so the CLI/specs can inspect the
          # pseudo-code without touching disk.
          def build
            files = PseudoCodeBuilder.new(scanner: CallbackChainScanner.new(app_dir: @app_dir), app_dir: @app_dir).build
            files + framework_source_files
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
              files.each do |file|
                path = File.join(dir, file.filename)
                # A transcription mirrors the gem's layout, so its filename is a
                # PATH — `action_controller/metal/http_authentication.rb` — and
                # its directory has to exist before the write.
                FileUtils.mkdir_p(File.dirname(path))
                File.write(path, file.source)
              end
            end

            dir
          end

          private

          # The framework's own source, transcribed from the installed gem
          # (felixefelip/rbs_infer#144). Emitted by THIS generator, into THIS
          # sidecar, because it is the same subject: how a request actually
          # flows. Absent when nothing could be resolved — a Rails version that
          # moved the methods, or an environment without Rails loaded.
          def framework_source_files
            return [] unless @transcribe_framework

            FrameworkSourceTranscriber.new.build.map do |file|
              PseudoCodeBuilder::FileEntry.new(filename: file[:filename], source: file[:source])
            end
          end
        end
      end
    end
  end
end
