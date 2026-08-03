# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module Controllers
        # Transcribes the FRAMEWORK'S OWN SOURCE into the controller-runtime
        # sidecar (felixefelip/rbs_infer#144).
        #
        # A fact can be true because of what a gem does with a block, and no
        # amount of reading the application will show it. `Current.identity =`
        # inside
        #
        #   authenticate_or_request_with_http_token do |token|
        #     Current.identity = identity if identity = ...
        #   end
        #
        # holds on every exit that did not render a 401 — because Rails returns
        # the block's value when it is truthy and renders otherwise. That is
        # ordinary Ruby, three methods deep in actionpack; it is invisible only
        # because a gem is described by RBS, which carries types and not flow.
        #
        # So the pseudo-code here is not a model of what Rails "effectively
        # does": it IS the gem's code, sliced from the installed version at
        # generation time. The generators run inside the app with Rails loaded,
        # so `source_location` points at the real file, and the transcription
        # tracks whatever version is installed rather than drifting from it.
        #
        # What this buys is nothing on its own — following it needs the
        # inference to carry a block's return through a delegation chain. It is
        # stage 1 of #144, and it exists so stages 2 and 3 have real code to be
        # right about instead of a hand-written summary to agree with.
        class FrameworkSourceTranscriber
          # A body is transcribed into ITS OWN OWNER, and the owner is read off
          # the method rather than chosen. The choice looked free and is not: a
          # body carries references that resolve by the lexical nesting of where
          # it was WRITTEN. `Token.authenticate(self, &login_procedure)` moved
          # into `ActionController::Base` stops resolving, because the nesting
          # there is `[Base, ActionController]` and no `ActionController::Token`
          # exists — Ruby raises the same NameError the checker reports.
          #
          # Keeping the owner means the transcription is verbatim, with no `def`
          # line rewritten, and it means the RBS collection must stop declaring
          # what is transcribed: RBS refuses two declarations of one method on
          # one owner, and now there is only one place the method can live.
          # Declarations have a free owner; bodies do not.
          Seed = Struct.new(:receiver, :method_name, keyword_init: true)

          SEEDS = [
            Seed.new(
              receiver: "ActionController::HttpAuthentication::Token::ControllerMethods",
              method_name: :authenticate_or_request_with_http_token
            ),
            Seed.new(
              receiver: "ActionController::HttpAuthentication::Token::ControllerMethods",
              method_name: :authenticate_with_http_token
            ),
            Seed.new(
              receiver: "ActionController::HttpAuthentication::Token",
              method_name: :authenticate
            ),
            # The `||`'s other operand, and the two frames that carry its halt.
            # Their TYPES were never in question — what is missing without them
            # is the proof that reaching this operand RENDERS, which is what
            # makes the chain's fact sound (felixefelip/steep#126).
            Seed.new(
              receiver: "ActionController::HttpAuthentication::Token::ControllerMethods",
              method_name: :request_http_token_authentication
            ),
            Seed.new(
              receiver: "ActionController::HttpAuthentication::Token",
              method_name: :authentication_request
            )
          ].freeze

          # A transcribed module is a MIXIN, and the `self` its body runs with is
          # whoever includes it — which the module cannot state and the
          # transcription therefore has to. Without it
          # `Token.authentication_request(self, …)` takes an `untyped`
          # controller, so `controller.render` resolves to no declaration and
          # the 401 cannot be seen to halt (felixefelip/steep#128).
          #
          # RBS says it already — the collection declares the `include` on
          # `ActionController::Base` — but what reads mixins here reads Ruby, so
          # the fact has to exist in Ruby to be read (felixefelip/rbs_infer#164
          # is the other way round, and heavier).
          #
          # Curated like the seeds and, like them, never asserted: emitted only
          # when the loaded runtime confirms the include, so a Rails version that
          # rearranges its mixins drops the file instead of lying about it.
          Mixin = Struct.new(:host, :module_name, keyword_init: true)

          MIXINS = [
            Mixin.new(
              host: "ActionController::Base",
              module_name: "ActionController::HttpAuthentication::Token::ControllerMethods"
            )
          ].freeze

          # The sidecar mirrors the gem's own layout: a body from
          # `actionpack/lib/action_controller/metal/http_authentication.rb` lands
          # in `<sidecar>/action_controller/metal/http_authentication.rb`. The
          # provenance is then readable from the path, and files cannot collide
          # as more of the framework is transcribed.
          LIB_SPLIT = "/lib/"

          # Returns the file's source, or nil when nothing could be transcribed —
          # a Rails version that renamed or removed a seed, or an environment
          # where the constant is not loaded. Missing seeds are SKIPPED rather
          # than raised on: a generator that dies on a framework upgrade is worse
          # than one that emits less.
          # => [{ filename:, source: }], one per transcribed gem FILE.
          def build
            SEEDS.filter_map { |seed| transcribe(seed) }
                 .group_by { |file, _, _| file }
                 .map { |file, entries| file_for(file, entries) }
                 .concat(mixin_files)
          end

          private

          # One file per host, carrying only its `include`s. Separate from the
          # bodies because what reads these attributes a file's includes to the
          # ONE class the file declares, and a transcription file declares
          # several modules.
          def mixin_files
            MIXINS.select { |mixin| mixed_in?(mixin) }
                  .group_by(&:host)
                  .map { |host, mixins| { filename: host_path(host), source: mixin_source(host, mixins) } }
          end

          # Asked of the loaded runtime, not of the list: the list says where to
          # look, the process says whether it is still true.
          def mixed_in?(mixin)
            Object.const_get(mixin.host).include?(Object.const_get(mixin.module_name))
          rescue NameError
            false
          end

          # `ActionController::Base` → `action_controller/base.rb`, the same
          # gem-shaped layout the transcribed bodies use.
          def host_path(host)
            "#{host.split('::').map { |segment| underscore(segment) }.join('/')}.rb"
          end

          def underscore(segment)
            segment.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
          end

          def mixin_source(host, mixins)
            includes = mixins.map { |mixin| "include #{mixin.module_name}" }

            mixin_header + wrap(host.split("::"), includes)
          end

          def mixin_header
            <<~HEADER
              # frozen_string_literal: true
              #
              # GENERATED by #{self.class.name}.
              # Regenerated on every run; do not edit.
              #
              # Who includes the modules transcribed alongside this file, read off
              # the loaded runtime at generation time. A mixin's body runs with the
              # includer's `self`, and the module cannot say who that is — so
              # without this the `self` it hands out is untyped, and everything it
              # is passed into with it (felixefelip/rbs_infer#144).

            HEADER
          end

          def file_for(path, entries)
            blocks = entries.group_by { |_, namespace, _| namespace }
                            .map { |namespace, rows| wrap(namespace, rows.map(&:last)) }

            { filename: sidecar_path(path), source: header + blocks.join("\n") }
          end

          # The path below the gem's `lib/`, which is the gem's own layout.
          def sidecar_path(path)
            index = path.rindex(LIB_SPLIT) or return File.basename(path)

            path[(index + LIB_SPLIT.length)..]
          end

          def header
            <<~HEADER
              # frozen_string_literal: true
              #
              # GENERATED by #{self.class.name}.
              # Regenerated on every run; do not edit.
              #
              # The framework's own source, transcribed from the installed gem so
              # the checker can follow the flow an RBS signature cannot express
              # (felixefelip/rbs_infer#144). Bodies land in the owner they were
              # written in, so their constant references resolve by the same
              # lexical nesting the gem relies on, and the file mirrors the gem's
              # own path.
              #
              # Verbatim but for one mechanical rewrite: `x.__send__(:foo, …)`
              # and its `send`/`public_send` siblings are written `x.foo(…)`.
              # Steep resolves none of the three, so the call would be a dead end
              # for every fact that depends on what it reached.

            HEADER
          end

          # `[source_file, namespace, source]` for a seed, or nil when it cannot
          # be reached. The namespace is the method's OWNER, so the body lands
          # back in the nesting it was written in.
          def transcribe(seed)
            method = resolve(seed) or return nil
            owner = method.owner.name or return nil
            file, line = method.source_location
            return nil unless file && line && File.file?(file)

            node = def_node_at(file, line) or return nil
            [file, owner.split("::"), dedent(desugar_dynamic_sends(node), node.location.start_column)]
          end

          # `controller.__send__ :render, …` → `controller.render …`
          #
          # The one deviation from a verbatim body, and a mechanical one: the
          # same call written without the indirection. Steep resolves none of
          # `__send__`, `send` or `public_send` — measured, all three type as
          # their `Kernel`/`BasicObject` declaration returning `untyped` — so the
          # call-graph edge is lost, and with it every fact that depends on what
          # the method reached. Rails renders the 401 that way, and that render
          # is what proves the `||` tail halts (felixefelip/steep#126).
          #
          # Only with a LITERAL symbol: with a variable there is no name to put
          # in its place. And only meaning-preserving while the target is public
          # — `__send__` reaches private methods, a plain call does not. When it
          # is not, the transcription reports a visibility error the real code
          # does not have: wrong, but wrong out loud, which is the trade taken
          # rather than teaching the checker to read symbols.
          SEND_ALIASES = %i[__send__ send public_send].freeze

          def desugar_dynamic_sends(node)
            source = node.slice.dup
            origin = node.location.start_offset

            edits = RbsInfer::Analyzer.find_all_nodes(node) { |n| dynamic_send?(n) }.flat_map do |call|
              symbol, *rest = call.arguments.arguments
              # The argument list loses the symbol; the message keeps its place,
              # spelled with the symbol's own name.
              [[call.message_loc.start_offset - origin, call.message_loc.end_offset - origin, symbol.unescaped],
               [symbol.location.start_offset - origin,
                (rest.first&.location&.start_offset || symbol.location.end_offset) - origin, ""]]
            end

            # Back to front, so an earlier edit cannot shift a later offset.
            edits.sort_by { |start, _, _| -start }.each { |start, finish, text| source[start...finish] = text }
            source
          end

          def dynamic_send?(node)
            return false unless node.is_a?(Prism::CallNode) && SEND_ALIASES.include?(node.name)

            node.arguments&.arguments&.first.is_a?(Prism::SymbolNode)
          end

          def resolve(seed)
            Object.const_get(seed.receiver).instance_method(seed.method_name)
          rescue NameError
            nil
          end

          # The `def` whose own line is `line`. Located by position rather than by
          # name so a file defining the same name twice cannot be confused.
          def def_node_at(file, line)
            result = Prism.parse_file(file)
            return nil unless result.success?

            RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::DefNode) }
                              .find { |n| n.location.start_line == line }
          end

          # `node.slice` starts AT the `def` keyword, so the first line carries no
          # indentation while the rest keep the file's. The margin to strip is
          # therefore the def's own column, not the minimum across lines — which
          # is zero, and left every body at the gem's absolute indentation.
          def dedent(source, margin)
            first, *rest = source.lines
            ([first] + rest.map { |line| line.strip.empty? ? line : line.sub(/\A {0,#{margin}}/, "") }).join
          end

          # Nests the defs under `namespace`, `class` for a constant that is one
          # and `module` otherwise, so the reopen matches what is being reopened.
          def wrap(namespace, defs)
            body = defs.join("\n\n").rstrip
            depth = namespace.size

            lines = namespace.each_with_index.map { |segment, i| "#{'  ' * i}#{keyword_for(namespace[0..i])} #{segment}" }
            lines << body.lines.map { |l| l.strip.empty? ? l : "#{'  ' * depth}#{l}" }.join
            lines.concat((0...depth).to_a.reverse.map { |i| "#{'  ' * i}end" })
            "#{lines.join("\n")}\n"
          end

          def keyword_for(path)
            Object.const_get(path.join("::")).is_a?(Class) ? "class" : "module"
          rescue NameError
            "module"
          end
        end
      end
    end
  end
end
