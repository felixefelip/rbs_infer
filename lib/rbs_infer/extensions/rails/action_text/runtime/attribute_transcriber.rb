# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module ActionText
        module Runtime
          # Slices `has_rich_text` out of the installed ActionText, and states who
          # is extended by the module it lives in.
          #
          # That is the whole extension. What the macro DOES —
          #
          #   class_eval <<-CODE
          #     def #{name}
          #       rich_text_#{name} || build_rich_text_#{name}
          #     end
          #   CODE
          #
          # — is read by `Project::StringEvalMacroExpander`, which knows nothing
          # about Rails: it renders any `class_eval` of an interpolated string at
          # the call sites that supply the interpolation. So nothing here has to
          # know that `store_if_blank:` selects a different writer, or that a
          # symbol and a string name the same attribute. The gem says it, and the
          # core reads it.
          #
          # Transcribed rather than summarised, for the reason
          # `Controllers::FrameworkSourceTranscriber` gives: a paraphrase
          # describes some other method. This one is sliced from the version that
          # is installed, so a Rails that rewrites the macro lands here on its
          # own rather than drifting from a copy.
          module AttributeTranscriber
            # Reached by name, never as a bare constant: `ActionText` inside this
            # namespace is OUR module, not the gem's.
            RECEIVER = "ActionText::Attribute::ClassMethods"
            MACRO = :has_rich_text

            # Who takes the transcribed module. A module is a MIXIN, and the
            # `self` its body runs with is whoever includes it — which the module
            # cannot say and the transcription therefore has to, or the
            # `has_one`/`scope` the macro also calls resolve against nothing (the
            # same fact `FrameworkSourceTranscriber` emits for its `include`s).
            #
            # `ActionText::Attribute` is an `ActiveSupport::Concern`, so the
            # engine's `include` is what `extend`s its `ClassMethods` — and it is
            # `ClassMethods` the macro is written in, so the extend is the fact
            # this file needs.
            EXTENDER = "ActiveRecord::Base"

            # Read from the ENGINE'S SOURCE rather than from the loaded runtime,
            # unlike the controller transcriber's mixins: the engine states it
            # inside `ActiveSupport.on_load(:active_record)`, which has not run
            # unless a Rails app booted — so asking the process would answer
            # differently depending on whether the generator was invoked by the
            # rake task or by a plain script, and write a different file each
            # time. The gem's own source says the same thing either way.
            ENGINE_PATH = "action_text/engine.rb"
            HOOK = :on_load
            HOOK_ARGUMENT = "active_record"
            MIXED_IN = "ActionText::Attribute"

            FILENAME = "attribute.rb"

            module_function

            # => { filename:, source: }, or nil when there is nothing to slice —
            # a Rails that renamed the macro, or an app without ActionText. nil
            # rather than a guess: a generator that dies on a framework upgrade
            # is worse than one that emits less.
            def file_entry
              body = macro_source or return nil

              { filename: FILENAME, source: header + wrap(body) }
            end

            # The one deviation from a verbatim body, and the same mechanical
            # kind as the controller transcriber's `__send__` rewrite:
            # `# @rbs_infer |...` (#200) above the def, which makes the emitted
            # signature RBS's OVERLOADING form.
            #
            # Not a type — the marker states precedence, not a signature. It is
            # here because gem_rbs_collection already declares `has_rich_text`,
            # and a second plain declaration is a `DuplicatedMethodDefinitionError`
            # that poisons the whole environment rather than degrading. The
            # Concern transcription carries it on all three of its defs for
            # exactly this reason.
            OVERLOADING_MARKER = "# @rbs_infer |..."

            # The macro's own source, dedented to column zero and marked.
            def macro_source
              node = macro_def_node or return nil

              "#{OVERLOADING_MARKER}\n#{dedent(node.slice, node.location.start_column)}"
            end

            def macro_def_node
              require "action_text" unless Object.const_defined?(:ActionText)

              method = Object.const_get(RECEIVER).instance_method(MACRO)
              file, line = method.source_location
              return nil unless file && line && File.file?(file)

              result = Prism.parse_file(file)
              return nil unless result.success?

              # By POSITION, not by name, so a file defining the name twice
              # cannot be confused — the rule the controller transcriber locates
              # its seeds by.
              RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::DefNode) }
                                .find { |n| n.location.start_line == line }
            rescue LoadError, NameError
              nil
            end

            # Whether the engine still mixes the module into Active Record —
            # `ActiveSupport.on_load(:active_record) do include ActionText::Attribute end`,
            # located as that shape rather than by a substring, so a mention in a
            # comment or a different hook does not count.
            def mixed_in?
              root = engine_root or return false

              RbsInfer::Analyzer.find_all_nodes(root) { |n| on_load_active_record?(n) }
                                .any? { |node| includes_attribute?(node) }
            end

            def engine_root
              path = macro_def_node&.location && gem_file(ENGINE_PATH)
              return nil unless path && File.file?(path)

              result = Prism.parse_file(path)
              result.success? ? result.value : nil
            end

            # Beside the macro's own file, which is the only path this knows for
            # certain — `lib/action_text/attribute.rb` and `lib/action_text/engine.rb`
            # are siblings in the gem.
            def gem_file(relative)
              node = macro_def_node or return nil

              method = Object.const_get(RECEIVER).instance_method(MACRO)
              dir = File.dirname(File.dirname(method.source_location.first))
              File.join(dir, relative)
            rescue NameError
              nil
            end

            def on_load_active_record?(node)
              node.is_a?(Prism::CallNode) && node.name == HOOK && node.block &&
                node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) &&
                node.arguments.arguments.first.unescaped == HOOK_ARGUMENT
            end

            def includes_attribute?(node)
              RbsInfer::Analyzer.find_all_nodes(node.block) do |n|
                n.is_a?(Prism::CallNode) && n.name == :include && n.receiver.nil?
              end.any? do |call|
                RbsInfer::Analyzer.extract_constant_path(call.arguments&.arguments&.first)
                                  &.delete_prefix("::") == MIXED_IN
              end
            end

            def wrap(body)
              nesting = RECEIVER.split("::")
              indented = body.rstrip.lines
                             .map { |line| line.strip.empty? ? "\n" : "#{'  ' * nesting.size}#{line}" }.join

              opens = nesting.each_with_index.map { |segment, i| "#{'  ' * i}module #{segment}" }
              closes = (0...nesting.size).to_a.reverse.map { |i| "#{'  ' * i}end" }

              "#{(opens + [indented] + closes).join("\n")}\n#{extend_source}"
            end

            def extend_source
              return "" unless mixed_in?

              "\nclass #{EXTENDER}\n  extend #{RECEIVER}\nend\n"
            end

            # `node.slice` starts AT the `def` keyword, so its first line carries
            # no indentation while the rest keep the file's. The margin to strip
            # is the def's own column, not the minimum across lines.
            def dedent(source, margin)
              first, *rest = source.lines
              ([first] + rest.map { |line| line.strip.empty? ? line : line.sub(/\A {0,#{margin}}/, "") }).join
            end

            def header
              <<~HEADER
                # frozen_string_literal: true
                #
                # GENERATED by RbsInfer::Extensions::Rails::ActionText::RuntimeGenerator.
                # Regenerated on every run; do not edit.
                #
                # `has_rich_text`, transcribed from the installed ActionText. The methods
                # it defines are written with `class_eval` on a heredoc STRING, which is
                # where every static reader stops — so the source is put here, and
                # `Project::StringEvalMacroExpander` renders it at the call sites that
                # supply the interpolation. Nothing in this file, or in the generator that
                # wrote it, states a type.

              HEADER
            end
          end
        end
      end
    end
  end
end
