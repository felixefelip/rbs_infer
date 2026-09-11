# frozen_string_literal: true

require "fileutils"
require_relative "runtime/attribute_transcriber"

module RbsInfer
  module Extensions
    module Rails
      module ActionText
        # Puts ActionText's `has_rich_text` where the pipeline can read it.
        #
        # `has_rich_text :content` defines three ordinary methods plus one
        # `has_one`. The `has_one` is a reflection, so rbs_rails types it; the
        # three methods are written by `class_eval` on a heredoc STRING, and a
        # string is where every static reader stops — `ClassEvalExpander`
        # desugars the BLOCK form, and felixefelip/steep#135 declines the string
        # form for the same reason. So `post.content` is not `untyped` today: it
        # is a `NoMethodError`, because the method does not exist for the checker
        # at all.
        #
        # Nothing was missing but the SOURCE, and the source ships in a gem —
        # the same thing `ConcernPseudoCode` found for `included do … end`. So
        # this generator writes one file, holding the macro as ActionText wrote
        # it, and does no more:
        #
        #     module ActionText::Attribute::ClassMethods
        #       def has_rich_text(name, encrypted: false, …)
        #         class_eval <<-CODE
        #           def #{name}
        #             rich_text_#{name} || build_rich_text_#{name}
        #           end
        #         CODE
        #         …
        #       end
        #     end
        #
        # Rendering that at each `has_rich_text :content` is
        # `Project::StringEvalMacroExpander`'s job, and it is not a Rails
        # feature: `class_eval` of an interpolated string is a plain-Ruby idiom,
        # and the expander names no gem. The per-model methods are therefore
        # inferred, not generated — which is why this file can be one file, and
        # why an app that writes the same idiom in its own concern gets the same
        # treatment without a generator at all.
        #
        # Nothing here states a type. `content` is `::ActionText::RichText`
        # because `rich_text_content || build_rich_text_content` is — the union
        # of rbs_rails' nilable reader and its non-nilable builder — and
        # `content?` is `bool` because `.present?` is.
        #
        # Runs after rbs_rails, which supplies those two.
        #
        # KNOWN GAP — four diagnostics in the emitted file, recorded in the
        # dummy's steep baseline. The macro's tail calls `has_one`, `scope`,
        # `where`, `includes` and `strict_loading_by_default`, and the `self` the
        # transcription can state is `singleton(ActiveRecord::Base)` (the module
        # is extended into the base class, which is the fact the engine
        # establishes). Four of those methods are not declared THERE: rbs_rails'
        # design puts `where`/`includes` in the generic
        # `ActiveRecord::Relation::ClassMethods[Model, Relation, …]` that each
        # concrete model extends, because the base class has no concrete
        # `Relation` to return. At runtime the macro only ever runs with a
        # concrete model as `self`, so the fact is true and the type is not
        # expressible yet — closing it needs the per-invoker self type
        # (`InvokerSelfTypes`) to reach a module method the extend was found for.
        #
        # The tail is transcribed anyway: the alternative is an edited copy of
        # the method, and an edited copy is what "a paraphrase describes some
        # other method" warns about. The four calls are also the ones the
        # pipeline reads nothing from — they are reflections, and rbs_rails
        # already types what they declare.
        class RuntimeGenerator
          # NOT dot-prefixed: `.rb` SOURCE the analyzer and the Steep fork read
          # through a `sig/**/*.rb` glob, and `**` skips hidden (dot) dirs.
          SIDECAR_DIR = "sig/generated/steep_actiontext_runtime"

          def initialize(app_dir:)
            @app_dir = app_dir
          end

          # => [{ filename:, source: }] — empty when ActionText is not installed
          # or the macro could not be read.
          #
          # It does not depend on the app: the file describes the FRAMEWORK, and
          # is written whether or not a model declares the macro — the same rule
          # the AR-runtime generator's Concern transcription follows, and for the
          # same reason. The first model to write `has_rich_text` would otherwise
          # be the thing that made the framework appear.
          def build
            entry = Runtime::AttributeTranscriber.file_entry
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
