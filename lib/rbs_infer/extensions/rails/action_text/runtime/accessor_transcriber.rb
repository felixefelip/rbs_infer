# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module ActionText
        module Runtime
          # The accessor bodies `has_rich_text` writes, TRANSCRIBED from the
          # installed gem rather than restated here.
          #
          # `has_rich_text :content` is not a fact about types that has to be
          # asserted — it is three ordinary methods, and ActionText writes them
          # itself:
          #
          #   class_eval <<-CODE
          #     def #{name}
          #       rich_text_#{name} || build_rich_text_#{name}
          #     end
          #     ...
          #   CODE
          #
          # They are invisible to every static reader only because the heredoc is
          # a STRING: `ClassEvalExpander` desugars `class_eval` with a BLOCK, and
          # felixefelip/steep#135 declines the string form for the same reason —
          # neither can see inside one. So the string is opened here, at
          # generation time, where the gem is loaded and `#{name}` has a value.
          #
          # Slicing beats restating for the same reason it does in
          # `Controllers::FrameworkSourceTranscriber`: this IS the gem's code,
          # from the installed version, so it tracks the version rather than
          # drifting from it. Rails 8.1 added `store_if_blank:` and a second
          # writer body with it; nothing here had to know that, because the
          # branch is read off the macro's own source (below) instead of being
          # re-implemented.
          module AccessorTranscriber
            # Reached by name, never by a bare constant: `ActionText` inside this
            # namespace is OUR module, not the gem's.
            RECEIVER = "ActionText::Attribute::ClassMethods"
            MACRO = :has_rich_text

            module_function

            # The accessor `def`s for one `has_rich_text`, as source, or nil when
            # the macro cannot be read — a Rails version that renamed it, an
            # environment where ActionText is not loaded, a rewritten body this
            # cannot follow, or an option whose value is not decidable here.
            #
            # nil rather than a guess, and nil for the WHOLE macro rather than
            # per body: emitting the reader without the writer is not "less", it
            # is a class that silently has no `content=`. A generator that emits
            # less than it could beats one that emits something wrong, and both
            # beat one that dies on a framework upgrade.
            #
            # options: the call site's keyword arguments, `{ "store_if_blank" =>
            # <Prism node> }`, which override the macro's own defaults.
            def transcribe(name:, options: {})
              node = macro_def_node or return nil
              defaults = keyword_defaults(node)

              chunks = []
              collect(node.body, [], chunks)
              return nil if chunks.empty? || chunks.any? { |chunk| chunk[:parts].nil? }

              selected = chunks.select do |chunk|
                held = guards_hold?(chunk[:guards], options, defaults)
                return nil if held == :undecidable

                held
              end
              return nil if selected.empty?

              selected.map { |chunk| render(chunk[:parts], name) }.join("\n")
            end

            # The `def has_rich_text` node, memoized: every attribute in the app
            # reads the same macro, and re-parsing the gem file per attribute is
            # the whole cost of this generator.
            def macro_def_node
              return @macro_def_node if defined?(@macro_def_node)

              @macro_def_node = locate_macro_def
            end

            def locate_macro_def
              # A rake task runs with the frameworks loaded, so under Rails the
              # constant is already there; this is for the standalone paths (the
              # Makefile targets, the specs) and it is what makes an app WITHOUT
              # ActionText emit nothing instead of raising — the macro cannot be
              # read, so no model can have called it.
              require "action_text" unless Object.const_defined?(:ActionText)

              method = Object.const_get(RECEIVER).instance_method(MACRO)
              file, line = method.source_location
              return nil unless file && line && File.file?(file)

              result = Prism.parse_file(file)
              return nil unless result.success?

              # By POSITION, not by name, so a file defining the name twice
              # cannot be confused — the same rule the controller transcriber
              # locates its seeds by.
              RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::DefNode) }
                                .find { |n| n.location.start_line == line }
            rescue LoadError, NameError
              nil
            end

            # `{ "store_if_blank" => <Prism node> }` — the macro's own defaults,
            # read from its parameter list. A default that is an expression
            # rather than a literal (`strict_loading: strict_loading_by_default`)
            # is kept as its node and decided, or not, by `truthy?`.
            def keyword_defaults(node)
              keywords = node.parameters&.keywords || []
              keywords.to_h { |kw| [kw.name.to_s, kw.respond_to?(:value) ? kw.value : nil] }
            end

            # Walks the macro body collecting each `class_eval`'s string argument
            # together with the conditions it sits under, so a body Rails only
            # writes in one branch is only transcribed in that branch.
            #
            # The guard is carried as the predicate NODE plus the branch's
            # polarity; nothing is evaluated here, because which branch is live
            # depends on the call site and this walk does not have one.
            def collect(node, guards, acc)
              return unless node.is_a?(Prism::Node)

              case node
              when Prism::IfNode
                collect(node.statements, guards + [[node.predicate, true]], acc)
                collect(node.subsequent, guards + [[node.predicate, false]], acc)
              when Prism::UnlessNode
                collect(node.statements, guards + [[node.predicate, false]], acc)
                collect(node.else_clause, guards + [[node.predicate, true]], acc)
              when Prism::CallNode
                if node.name == :class_eval && (arg = node.arguments&.arguments&.first)
                  acc << { guards: guards, parts: parts_of(arg) }
                  return
                end

                node.compact_child_nodes.each { |child| collect(child, guards, acc) }
              else
                node.compact_child_nodes.each { |child| collect(child, guards, acc) }
              end
            end

            # `[[:str, "  def "], [:name], …]`, or nil for a string this cannot
            # rebuild — one interpolating anything but the attribute name, or an
            # argument that is not a literal string at all.
            def parts_of(node)
              case node
              when Prism::StringNode
                [[:str, node.content]]
              when Prism::InterpolatedStringNode
                node.parts.map { |part| part_of(part) }.then { |parts| parts.all? ? parts : nil }
              end
            end

            def part_of(part)
              case part
              when Prism::StringNode
                [:str, part.content]
              when Prism::EmbeddedStatementsNode
                body = part.statements&.body
                [:name] if body&.size == 1 && names_the_attribute?(body.first)
              end
            end

            # `#{name}` — the macro's own parameter, read either as a local
            # variable or (before Prism knows it is one) as a receiverless call.
            def names_the_attribute?(node)
              case node
              when Prism::LocalVariableReadNode then node.name == :name
              when Prism::CallNode then node.receiver.nil? && node.arguments.nil? && node.name == :name
              else false
              end
            end

            # true / false / :undecidable — a guard is only held when every
            # condition resolves to a literal that says so.
            def guards_hold?(guards, options, defaults)
              guards.each do |predicate, polarity|
                value = guard_value(predicate, options, defaults)
                return :undecidable if value == :undecidable
                return false unless value == polarity
              end

              true
            end

            def guard_value(predicate, options, defaults)
              option = option_name(predicate) or return :undecidable
              node = options.fetch(option) { defaults[option] }

              truthy?(node)
            end

            # The keyword the predicate reads, for a predicate that is nothing
            # but a keyword read (`if store_if_blank`). Anything else — a
            # negation, a comparison, a call — is not decided here.
            def option_name(predicate)
              case predicate
              when Prism::LocalVariableReadNode then predicate.name.to_s
              when Prism::CallNode
                predicate.name.to_s if predicate.receiver.nil? && predicate.arguments.nil? && predicate.block.nil?
              end
            end

            def truthy?(node)
              case node
              when Prism::TrueNode then true
              when Prism::FalseNode, Prism::NilNode then false
              else :undecidable
              end
            end

            def render(parts, name)
              source = parts.map { |part| part.first == :name ? name : part.last }.join

              dedent(source)
            end

            # The heredoc body carries the gem's own indentation, and the reopen
            # supplies its own. Stripped by the SMALLEST indentation any of its
            # lines has, so the body's internal shape (an `if` inside the writer)
            # survives the move.
            def dedent(source)
              lines = source.lines
              margin = lines.reject { |line| line.strip.empty? }
                            .map { |line| line[/\A */].length }.min || 0

              lines.map { |line| line.strip.empty? ? line : line[margin..] }.join
            end
          end
        end
      end
    end
  end
end
