# frozen_string_literal: true

require "fileutils"
require_relative "runtime/delegation_transcriber"

module RbsInfer
  module Extensions
    module Rails
      module ActiveSupport
        # Puts ActiveSupport's `delegate` where the pipeline can read it.
        #
        # `delegate :email, to: :user` defines an ordinary method, written by
        # `module_eval` on a STRING the macro builds — and a string is where
        # every static reader stops. The core used to read the macro by hand
        # instead (`ClassMemberCollector#extract_delegates`), which is an
        # ActiveSupport concept in the core and guessed what the gem decides:
        # the receiver's class from its reader's NAME, nothing at all for
        # `to: :@ivar` or `to: SomeModule` (felixefelip/rbs_infer#355).
        #
        # As for `has_rich_text` (`ActionText::RuntimeGenerator`), nothing was
        # missing but the source, and the source ships in a gem. This generator
        # writes one file holding it and does no more; the checker folds what
        # each call site writes (felixefelip/steep#171) and
        # `Project::StringEvalMacroExpander` places it in the class whose body
        # made the call.
        #
        # Nothing here states a type. `(user).email` is typed by what `user`
        # returns, because the folded body is an ordinary call.
        #
        # KNOWN GAP — four diagnostics in the emitted file, recorded in the
        # dummy's steep baseline. Two errors: `caller_locations(1, 1).first`,
        # in `delegate` and in `generate` — core RBS declares
        # `caller_locations` as returning `Array[Location]?`, nil for a frame
        # past the top of the stack, which a method body never is. Two
        # warnings: `method_def = []` and `method_names = []` carry no element
        # type. Transcribed anyway, for the reason the ActionText generator
        # gives: an edited copy is a different method.
        class RuntimeGenerator
          # NOT dot-prefixed: `.rb` SOURCE the analyzer and the Steep fork read
          # through a `sig/**/*.rb` glob, and `**` skips hidden (dot) dirs.
          SIDECAR_DIR = "sig/generated/steep_activesupport_runtime"

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # => [{ filename:, source: }] — empty when ActiveSupport is not
          # installed or the macro could not be read.
          #
          # It does not depend on the app: the file describes the FRAMEWORK, and
          # is written whether or not a class calls the macro — the rule the
          # ActionText generator follows, for the same reason.
          def build
            entry = Runtime::DelegationTranscriber.file_entry
            entry ? [entry] : []
          end

          # Writes the sidecar dir, dropping a stale one when nothing qualifies.
          # Returns the sidecar dir path.
          def generate
            files = build
            dir = File.join(@app_dir, SIDECAR_DIR)

            FileUtils.rm_rf(dir)
            unless files.empty?
              FileUtils.mkdir_p(dir)
              files.each { |file| File.write(File.join(dir, file[:filename]), file[:source]) }
            end

            dir
          end
        end
      end
    end
  end
end
