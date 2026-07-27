# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module Views
        # Reads one ERB template and reports, purely syntactically, the two things the
        # view-runtime pseudo-code needs:
        #
        #   * `ivars` — the instance variables the template READS. This is what the view
        #     needs from its controller, so it is what the generated `initialize` takes.
        #     Deriving it from the template (rather than from the controller action) keeps
        #     the view the declarer of its own requirements; the controller-runtime render
        #     override then passes exactly these.
        #   * `renders` — one entry per `render` of a partial, with the locals as SOURCE
        #     EXPRESSIONS, not types. Types are never computed here: the pseudo-code
        #     re-emits the expression and the analyzer types it like any other call site.
        #     That is the whole point of the rewrite — see Views::PseudoCodeBuilder.
        #
        # A render reached from inside an iterator block (`@comments.each do |comment|`)
        # carries that block as `iteration`, so the builder can reproduce the loop and let
        # the pipeline derive the element type instead of resolving it by hand.
        class TemplateScanner
          # `locals` maps local name => Ruby source for the value. `iteration`, when set,
          # is `{ receiver:, param: }` for the enclosing `<collection>.each do |param|`.
          Render = Struct.new(:partial, :locals, :iteration, keyword_init: true)
          Result = Struct.new(:ivars, :renders, keyword_init: true)

          def initialize(source)
            @source = source
          end

          def self.scan(source)
            new(source).scan
          end

          def scan
            tree = parse or return Result.new(ivars: [], renders: [])

            ivars = []
            renders = []
            walk(tree, ivars: ivars, renders: renders, iteration: nil)

            Result.new(ivars: ivars.uniq.sort, renders: renders)
          end

          private

          def parse
            require "herb"
            ruby = Herb.extract_ruby(@source, comments: true)
            Prism.parse(ruby).value
          rescue LoadError, StandardError
            nil
          end

          def walk(node, ivars:, renders:, iteration:)
            return unless node.is_a?(Prism::Node)

            ivars << node.name.to_s.delete_prefix("@") if node.is_a?(Prism::InstanceVariableReadNode)

            if (render = render_of(node))
              # A `collection:` render already carries its own (synthesized) iteration;
              # only an inline render borrows the enclosing `each`.
              render.iteration ||= iteration
              renders << render
            end

            inner = iteration_of(node) || iteration
            node.compact_child_nodes.each { |child| walk(child, ivars: ivars, renders: renders, iteration: inner) }
          end

          # `<receiver>.each do |param|` => `{ receiver:, param: }`, else nil. Only a
          # single required block parameter is modelled; anything else is not a shape the
          # pseudo-code can reproduce faithfully, so it is left alone.
          def iteration_of(node)
            return nil unless node.is_a?(Prism::CallNode) && node.name == :each
            return nil unless node.block.is_a?(Prism::BlockNode)
            return nil unless node.receiver

            params = node.block.parameters&.parameters
            return nil unless params.respond_to?(:requireds)
            required = params.requireds
            return nil unless required.size == 1 && required.first.respond_to?(:name)

            { receiver: source_of(node.receiver), param: required.first.name.to_s }
          end

          # A `render` call naming a partial => Render, else nil. Three shapes:
          #
          #   render partial: "posts/form", locals: { post: @post }
          #   render partial: "comment", collection: @comments
          #   render "posts/summary", post: @post          (shorthand: locals are kwargs)
          def render_of(node)
            return nil unless node.is_a?(Prism::CallNode) && node.name == :render

            args = node.arguments&.arguments or return nil
            return nil if args.empty?

            if args[0].is_a?(Prism::StringNode)
              locals = args[1].is_a?(Prism::KeywordHashNode) ? locals_from(args[1]) : {}
              return Render.new(partial: args[0].unescaped, locals: locals)
            end

            partial = nil
            locals = {}
            collection = nil

            args.each do |arg|
              next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

              arg.elements.each do |assoc|
                next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

                case assoc.key.value
                when "partial" then partial = assoc.value.is_a?(Prism::StringNode) ? assoc.value.unescaped : nil
                when "locals" then locals = locals_from(assoc.value) if assoc.value.is_a?(Prism::HashNode)
                when "collection" then collection = source_of(assoc.value)
                end
              end
            end

            return nil unless partial

            # `collection:` renders the partial once per element, binding the element to a
            # local named after the partial. Model it as the equivalent iteration so the
            # element type comes from the pipeline, not from unwrapping `Array[T]` here.
            if collection
              local = partial.split("/").last
              return Render.new(
                partial: partial,
                locals: { local => local },
                iteration: { receiver: collection, param: local }
              )
            end

            Render.new(partial: partial, locals: locals)
          end

          def locals_from(hash_node)
            hash_node.elements.each_with_object({}) do |assoc, acc|
              next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
              next unless assoc.value

              acc[assoc.key.value] = source_of(assoc.value)
            end
          end

          def source_of(node)
            node.slice
          end
        end
      end
    end
  end
end
