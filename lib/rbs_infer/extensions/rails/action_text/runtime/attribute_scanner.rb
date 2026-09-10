# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../../../ast/lexical_constant_resolver"

module RbsInfer
  module Extensions
    module Rails
      module ActionText
        module Runtime
          # One `has_rich_text :name, …`. The options are kept as their Prism
          # NODES rather than as values: what they mean is the macro's business,
          # and `AccessorTranscriber` reads them against the macro's own
          # parameter defaults.
          RichTextAttribute = Struct.new(:name, :options, keyword_init: true)

          # `include SomeConcern`, kept so a class can be given what the concerns
          # it includes declare.
          Include = Struct.new(:name, keyword_init: true)

          # One class or module, with what its body declares.
          Unit = Struct.new(:path, :class_name, :kind, :body, keyword_init: true) do
            def attributes
              # A re-declaration REPLACES the earlier one (Rails redefines the
              # methods), so the class's own macro wins over one a concern
              # registered at include time — and one name yields one accessor
              # set rather than two colliding ones.
              body.grep(RichTextAttribute).reverse.uniq(&:name).reverse
            end

            def includes
              body.grep(Include).map(&:name)
            end
          end

          # Finds `has_rich_text` in the app's own sources.
          #
          # Static, like every other runtime generator's scan, and for a reason
          # that is not preference: these run as plain rake tasks with no
          # `=> :environment`, so the frameworks are loaded (which is what lets
          # `AccessorTranscriber` reflect on the gem) but the app's models are
          # not. `Post.rich_text_association_names` would be the exact answer and
          # is not available to ask.
          module AttributeScanner
            MACRO = :has_rich_text

            module_function

            # => [Unit], one per class AND per module in the file.
            def scan(path:, source:)
              # A file with no macro is still scanned when it INCLUDES: the
              # macro it contributes may live in a concern, and dropping the
              # includer here would lose the splice silently. Deliberately
              # coarse — `include` matches far more than it needs to, and the
              # cost of a false positive is one parse.
              return [] unless source.include?(MACRO.to_s) || source.include?("include")

              result = Prism.parse(source)
              return [] unless result.success?

              units = []
              walk(result.value, [], path, units)
              units
            end

            # Carries the lexical nesting down, so `class Entry` inside
            # `module Blog` is `Blog::Entry` — the name a concern's `include` is
            # resolved against, and the name the reopen has to spell to reopen
            # the same class rather than declare a new top-level one.
            def walk(node, namespace, path, units)
              return unless node.is_a?(Prism::Node)

              unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
                node.compact_child_nodes.each { |child| walk(child, namespace, path, units) }
                return
              end

              name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)&.delete_prefix("::")
              # A constant path this cannot name (`class self::Thing`) stops the
              # walk: everything below it would be attributed to the wrong owner.
              return unless name

              qualified = (namespace + [name]).join("::")
              unit = unit_for(path, node, qualified)
              units << unit if unit

              walk(node.body, namespace + [name], path, units)
            end

            # The CLASS units, each carrying the attributes its concerns declare
            # as well as its own.
            #
            # A concern is where `has_rich_text` lands as often as a model body
            # is:
            #
            #   module Describable
            #     extend ActiveSupport::Concern
            #     included do
            #       has_rich_text :description
            #     end
            #   end
            #
            # `Post.rich_text_association_names` includes `description`, and
            # reading `post.rb` alone sees no macro at all — the same cross-file
            # half `ActiveRecord::Runtime::ConcernResolver` exists for. That one
            # is not reused here because it is typed to the AR generator's own
            # unit struct; when a third generator needs the splice, the two
            # should be promoted to one `Rails::Runtime` module rather than a
            # third copy appearing.
            def resolve(units)
              concerns = units.select { |unit| unit.kind == :module }
                              .to_h { |unit| [unit.class_name, unit] }

              units.select { |unit| unit.kind == :class }
                   .group_by(&:class_name)
                   .map { |class_name, reopens| merge(class_name, reopens, concerns) }
                   .reject { |unit| unit.attributes.empty? }
            end

            # Every reopen of one class is ONE model — Ruby reopens rather than
            # replaces — so a macro written in a second file counts too.
            def merge(class_name, reopens, concerns)
              Unit.new(
                path: reopens.first.path,
                class_name: class_name,
                kind: :class,
                body: reopens.flat_map { |unit| expand(unit, concerns, Set.new) }
              )
            end

            # The unit's body with each `Include` replaced by the included
            # module's own (recursively expanded) body, IN PLACE, so a concern's
            # declaration keeps its position relative to the class's own and the
            # last one still wins. An `include` naming something outside the
            # scanned sources contributes nothing rather than a guess.
            #
            # `visited` makes a re-include a no-op, as Ruby does, and cuts the
            # cycle a mutually-including pair would otherwise be.
            def expand(unit, concerns, visited)
              return [] unless visited.add?(unit.class_name)

              unit.body.flat_map do |entry|
                next [entry] unless entry.is_a?(Include)

                concern = lookup(entry.name, unit.class_name, concerns)
                concern ? expand(concern, concerns, visited) : []
              end
            end

            # `include Describable` inside `class Post` is `Post::Describable`
            # when that is what exists — Ruby resolves a bare constant from the
            # enclosing namespace outward, and a concern is conventionally nested
            # under its host. A module that would resolve to ITSELF is skipped:
            # a self-include cannot run, so it is never what the source meant.
            def lookup(name, enclosing, concerns)
              found = RbsInfer::AST::LexicalConstantResolver.resolve(
                name: name, enclosing: enclosing
              ) { |candidate| candidate != enclosing && concerns.key?(candidate) }

              found && concerns[found]
            end

            def unit_for(path, node, class_name)
              is_class = node.is_a?(Prism::ClassNode)
              body = is_class ? class_body(node) : module_body(node)
              return nil if body.empty?

              Unit.new(path: path, class_name: class_name, kind: is_class ? :class : :module, body: body)
            end

            def class_body(node)
              statements(node.body).flat_map { |stmt| entries_for(stmt) }
            end

            # A module's macro is written inside `included do … end` — at module
            # level `has_rich_text` is not defined, so a call there could not have
            # run. Both placements are read anyway: a module body that somehow
            # spells it means the same thing, and refusing it would only lose
            # what a reader can plainly see.
            def module_body(node)
              statements(node.body).flat_map do |stmt|
                next entries_for(stmt) unless stmt.is_a?(Prism::CallNode) && stmt.name == :included && stmt.block

                statements(stmt.block.body).flat_map { |inner| entries_for(inner) }
              end
            end

            def entries_for(stmt)
              return [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?

              case stmt.name
              when MACRO
                name = first_name(stmt) or return []
                [RichTextAttribute.new(name: name, options: keyword_nodes(stmt))]
              when :include
                name = RbsInfer::Analyzer.extract_constant_path(stmt.arguments&.arguments&.first)
                name ? [Include.new(name: name.delete_prefix("::"))] : []
              else
                []
              end
            end

            # `has_rich_text :content` and `has_rich_text "content"` name the
            # same attribute; Rails accepts either (`String | Symbol name`).
            def first_name(stmt)
              case (arg = stmt.arguments&.arguments&.first)
              when Prism::SymbolNode then arg.unescaped
              when Prism::StringNode then arg.content
              end
            end

            def keyword_nodes(stmt)
              last = stmt.arguments&.arguments&.last
              return {} unless last.is_a?(Prism::KeywordHashNode)

              last.elements.filter_map do |element|
                next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

                [element.key.unescaped, element.value]
              end.to_h
            end

            def statements(body)
              body.is_a?(Prism::StatementsNode) ? body.body : []
            end
          end
        end
      end
    end
  end
end
