# frozen_string_literal: true

require "fileutils"
require_relative "runtime/attribute_scanner"
require_relative "runtime/pseudo_code_builder"

module RbsInfer
  module Extensions
    module Rails
      module ActionText
        # Emits *pseudo-code* for what `has_rich_text` does at class-definition
        # time, so `post.content` is a method the checker can see.
        #
        # `has_rich_text :content` is three ordinary methods and one `has_one`.
        # The `has_one` is a reflection, so rbs_rails types it; the three methods
        # are written by `class_eval` on a HEREDOC STRING, and nothing static
        # reads inside one — `ClassEvalExpander` desugars the BLOCK form and
        # felixefelip/steep#135 declines the string form for the same reason. So
        # `post.content` is not `untyped` today, it is a `NoMethodError`: the
        # method does not exist for the checker at all.
        #
        # What the framework does is plain Ruby, and this writes it:
        #
        #     class Post
        #       def content
        #         rich_text_content || build_rich_text_content
        #       end
        #
        #       def content?
        #         rich_text_content.present?
        #       end
        #
        #       def content=(body)
        #         self.content.body = body
        #       end
        #     end
        #
        # Nothing here states a type. `content` is `::ActionText::RichText`
        # because `rich_text_content || build_rich_text_content` is — the union
        # of rbs_rails' nilable reader and its non-nilable builder — and
        # `content?` is `bool` because `.present?` is. The bodies are not written
        # by this generator either: they are sliced from the installed gem
        # (`Runtime::AccessorTranscriber`), so they track the Rails version
        # instead of drifting from it.
        #
        # Runs after rbs_rails, which is what supplies `rich_text_content` and
        # `build_rich_text_content` — the same ordering the Devise generator has.
        #
        # SCOPE: the app-side accessors. `ActionText::RichText`'s own methods
        # (`to_plain_text`, `to_trix_html`, and the `delegate`s to `body`) are
        # equally plain Ruby and equally transcribable, but they all read `body`,
        # which rbs_rails currently types `::String?` — its column type — rather
        # than `::ActionText::Content`, because its serializer handling special-
        # cases only JSON/Array/Hash coders. Transcribing them before that is
        # fixed would emit bodies that report an error instead of a type, so that
        # half waits on the rbs_rails coder fix.
        class RuntimeGenerator
          # NOT dot-prefixed: `.rb` SOURCE the analyzer and the Steep fork read
          # via a `sig/**/*.rb` glob, and `**` skips hidden (dot) directories.
          SIDECAR_DIR = "sig/generated/steep_actiontext_runtime"
          MODEL_ROOTS = %w[app/models].freeze

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # => [Runtime::PseudoCodeBuilder::FileEntry]. Public so the CLI and the
          # specs can read the pseudo-code without touching disk.
          def build
            Runtime::PseudoCodeBuilder.build(Runtime::AttributeScanner.resolve(scan_models))
          end

          # Writes the sidecar dir, dropping whatever a previous run left behind
          # — including the whole directory when the app no longer declares the
          # macro, so a removed `has_rich_text` cannot leave a reopen defining a
          # method that no longer exists.
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

          # Every class AND module under the model roots — a concern's
          # `included do` is as likely a home for the macro as a model body, and
          # only a scan that keeps both can splice one into the other.
          def scan_models
            MODEL_ROOTS.flat_map do |root|
              Dir.glob(File.join(@app_dir, root, "**/*.rb")).sort.flat_map do |abs|
                Runtime::AttributeScanner.scan(path: relative(abs), source: File.read(abs))
              rescue StandardError => e
                warn "[rbs_infer actiontext_runtime] skipped #{relative(abs)}: #{e.class}: #{e.message}"
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
