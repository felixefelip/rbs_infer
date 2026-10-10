# frozen_string_literal: true

require_relative "../../../framework_source"

module RbsInfer
  module Extensions
    module Rails
      module ActiveSupport
        module Runtime
          # Slices `delegate` out of the installed ActiveSupport: `Module#delegate`
          # and `Module#delegate_missing_to`, and the `ActiveSupport::Delegation`
          # they hand their arguments to.
          #
          # That is the whole extension. What `delegate :email, to: :user` DOES —
          #
          #   method_def <<
          #     "def #{method_name}(#{definition})" <<
          #     "  _ = #{receiver}" <<
          #     …
          #   owner.module_eval(method_def.join(";"), file, line)
          #
          # — is read by `Project::StringEvalMacroExpander`, which knows nothing
          # about ActiveSupport: it renders any `module_eval` of a string the
          # checker folds, at the call site that supplied the folding. So nothing
          # here knows that `prefix: true` names the method after the target, that
          # `to: :class` reads the target's parameter list, or that `allow_nil:`
          # writes a different body. The gem says it, and the checker reads it
          # (felixefelip/steep#171).
          #
          # Transcribed rather than summarised, for the reason
          # `Controllers::FrameworkSourceTranscriber` gives: a paraphrase
          # describes some other method. Sliced from the version that is
          # installed, so an ActiveSupport that rewrites the generator lands here
          # on its own.
          module DelegationTranscriber
            # Reached by name, never as a bare constant: `ActiveSupport` inside
            # this namespace is OUR module, not the gem's.
            MACROS = %i[delegate delegate_missing_to].freeze
            WRITER = "ActiveSupport::Delegation"
            WRITER_METHOD = :generate

            FILENAME = "delegation.rb"

            # `|...` (felixefelip/rbs_infer#200) makes the signature inferred for
            # each macro ADD to the one gem_rbs_collection declares, ahead of it,
            # rather than redeclare it — which RBS rejects as a duplicate.
            #
            # Ahead of it is the point. The gem's declaration is
            # `(*untyped methods, ?to: untyped? to, …)`, and an `untyped`
            # parameter cancels the checker's per-call-site specialization: the
            # literals `delegate :email, to: :user` passes would never reach the
            # body, and nothing below would fold. What is inferred instead comes
            # from the call sites the app writes, so this file still states no
            # type.
            OVERLOAD_MARKER = "# @rbs_infer |..."

            module_function

            # => { filename:, source: }, or nil when there is nothing to slice —
            # an ActiveSupport that renamed the macro or the writer. nil rather
            # than a guess: a generator that dies on a framework upgrade is worse
            # than one that emits less.
            def file_entry
              macros = macro_sources or return nil
              writer = writer_source or return nil

              { filename: FILENAME, source: header + module_source(macros) + "\n" + writer }
            end

            # Each macro's own source, at column zero and marked.
            def macro_sources
              load_active_support or return nil

              MACROS.map do |name|
                node = FrameworkSource.def_node(::Module.instance_method(name)) or return nil
                "#{OVERLOAD_MARKER}\n#{FrameworkSource.source(node)}"
              end
            rescue NameError
              nil
            end

            # The whole `module Delegation` the writer is a method of — not just
            # the method: `generate` reads `RESERVED_METHOD_NAMES`, and a
            # constant this file left out would be one the checker cannot fold.
            # Nested back into `module ActiveSupport`, where the gem writes it.
            def writer_source
              load_active_support or return nil

              file, line = Object.const_get(WRITER).method(WRITER_METHOD).source_location
              return nil unless file && line && File.file?(file)

              namespace, name = WRITER.split("::")
              node = FrameworkSource.enclosing_namespace(file, line, name) or return nil

              "module #{namespace}\n#{FrameworkSource.indent(FrameworkSource.source(node).rstrip, 1)}\nend\n"
            rescue NameError
              nil
            end

            def module_source(macros)
              body = macros.map(&:rstrip).join("\n\n")
              "class Module\n#{FrameworkSource.indent(body, 1)}\nend\n"
            end

            def load_active_support
              require "active_support"
              require "active_support/core_ext/module/delegation"
              true
            rescue LoadError
              false
            end

            def header
              <<~HEADER
                # frozen_string_literal: true
                #
                # GENERATED by RbsInfer::Extensions::Rails::ActiveSupport::RuntimeGenerator.
                # Regenerated on every run; do not edit.
                #
                # `delegate`, transcribed from the installed ActiveSupport. The methods
                # it defines are written with `module_eval` on a STRING, which is where
                # every static reader stops — so the source is put here, and
                # `Project::StringEvalMacroExpander` renders it at the call sites that
                # supply the folding. Nothing in this file, or in the generator that
                # wrote it, states a type.

              HEADER
            end
          end
        end
      end
    end
  end
end
