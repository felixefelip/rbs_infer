# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      # Builds the static render graph for partials (felixefelip/rbs_infer#25):
      # which ERB view/partial renders which html/turbo_stream partial. Used
      # to decide whether a partial is reachable ONLY from guard-covered
      # contexts, so its `Current.*` reads can be narrowed soundly.
      #
      # Conservative on completeness — `dynamic?` is set (the consumer must
      # then narrow NO partial) when the render surface can't be proven
      # complete:
      #   - a render whose partial target isn't a literal string
      #     (`render partial: var`, `render @collection`, `render method`);
      #   - a view that fails to convert/parse;
      #   - an alternative HTML template language we can't parse
      #     (`.haml`/`.slim`) — it could render an html partial unseen.
      # A partial rendered from a controller, layout, helper or component is
      # marked `external` (no single guarded action covers it → uncovered).
      #
      # Known boundary (not modeled): a partial reached via a *receivered*
      # render — `SomeController.render(partial:)` / `render_to_string` from a
      # job or service. Those run without the request guard; they're rare and
      # left out so unrelated `obj.render(...)` calls don't trip the bail.
      class PartialRenderGraph
        # Ruby surfaces where a bare `render` renders a view partial.
        RUBY_RENDER_DIRS = %w[controllers helpers components].freeze

        # renderer view-relative ("caderneta/index.html.erb") => Set of
        # partial keys ("caderneta/doses") it renders.
        attr_reader :edges
        # partial keys rendered from a controller, layout, helper or component
        # (→ uncovered: no single guarded action covers them).
        attr_reader :external
        # true when the render surface can't be proven complete.
        attr_reader :dynamic
        # partial key ("caderneta/doses") => its file view-relative
        # ("caderneta/_doses.html.erb"). The renderer-side node identity, so
        # a partial that itself renders other partials is found by key.
        attr_reader :partial_files

        def initialize(app_dir:)
          @app_dir = app_dir
          @edges = Hash.new { |h, k| h[k] = Set.new }
          @external = Set.new
          @partial_files = {}
          @dynamic = false
        end

        def dynamic? = @dynamic

        # File view-relative of `partial_key`, or nil if no partial file was
        # found for it (rendered but missing → nothing to narrow).
        def file_for(partial_key) = @partial_files[partial_key]

        # Renderer view-relatives ("caderneta/index.html.erb", …) that render
        # `partial_key`.
        def renderers_of(partial_key)
          @edges.each_with_object([]) do |(renderer, targets), acc|
            acc << renderer if targets.include?(partial_key)
          end
        end

        def build
          # An HTML template language we can't parse could render an html
          # partial we'd never see → can't prove completeness.
          @dynamic = true if Dir[File.join(@app_dir, "app/views/**/*.{haml,slim}")].any?

          Dir[File.join(@app_dir, "app/views/**/*.{html,turbo_stream}.erb")].sort.each do |erb_path|
            view_relative = erb_path.sub("#{@app_dir}/", "").sub(%r{\Aapp/views/}, "")
            scan_view(erb_path, view_relative)
          end

          RUBY_RENDER_DIRS.each do |dir|
            Dir[File.join(@app_dir, "app", dir, "**/*.rb")].sort.each { |path| scan_ruby(path) }
          end

          self
        end

        private

        def scan_view(erb_path, view_relative)
          record_partial_file(view_relative)

          ruby = erb_to_ruby(File.read(erb_path))
          # An ERB template compiles into a method body, so `<%= yield %>` and
          # friends are valid only inside one — wrap before parsing, else a
          # plain layout would spuriously fail and bail. A genuinely broken
          # template still fails to parse.
          parsed = ruby && Prism.parse("def __erb__\n#{ruby}\nend\n")
          # A view we can't convert/parse could hide a render → can't prove
          # the graph complete, so bail globally.
          if parsed.nil? || !parsed.success?
            @dynamic = true
            return
          end

          caller_dir = File.dirname(view_relative)
          caller_dir = nil if caller_dir == "."
          layout = view_relative.start_with?("layouts/")

          each_render(parsed.value) do |target|
            key = render_key(target, caller_dir)
            next unless key

            layout ? @external << key : @edges[view_relative] << key
          end
        rescue SystemCallError
          # Couldn't read the view file (the only non-bug error here — parse
          # failures surface via `success?`, not exceptions). A view we can't
          # read could hide a render → bail conservatively.
          @dynamic = true
        end

        # A bare `render` in controller/helper/component ruby isn't covered by
        # a single guarded action → mark its partial external (uncovered).
        def scan_ruby(path)
          each_render(Prism.parse(File.read(path)).value) do |target|
            key = render_key(target, nil)
            @external << key if key
          end
        rescue SystemCallError
          # Couldn't read the file → we may have missed an `external` mark that
          # keeps a partial uncovered. Bail rather than risk narrowing a
          # partial that's actually reachable without the guard.
          @dynamic = true
        end

        # Resolves a yielded render target to a partial key, or nil to skip.
        # `:dynamic` flips the global bail.
        def render_key(target, caller_dir)
          case target
          when :dynamic
            @dynamic = true
            nil
          when nil
            nil # not a partial render (template/symbol/component)
          else
            resolve_partial_key(target, caller_dir)
          end
        end

        # Yields each `render` call's partial target: a String (literal
        # partial name), `:dynamic` (unresolvable partial render), or nil (not
        # a partial render). Only bare `render` counts — `obj.render(...)` is
        # an unrelated method.
        def each_render(node, &block)
          if node.is_a?(Prism::CallNode) && node.name == :render && node.receiver.nil?
            yield render_target(node)
          end
          node.compact_child_nodes.each { |c| each_render(c, &block) }
        end

        def render_target(call)
          args = call.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args[0]
          # `render partial: ...` / explicit kwargs.
          if (kw = args.find { |a| a.is_a?(Prism::KeywordHashNode) })
            partial = kw.elements.find do |e|
              e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.value == "partial"
            end
            if partial
              return partial.value.is_a?(Prism::StringNode) ? partial.value.unescaped : :dynamic
            end
            # `render json:/plain:/template:/...` with no `partial:` and a
            # non-string first arg → not a partial render.
            return nil unless first.is_a?(Prism::StringNode)
          end

          case first
          when Prism::StringNode then first.unescaped # render "doses"
          when Prism::SymbolNode then nil             # render :new (template)
          when Prism::ConstantReadNode, Prism::ConstantPathNode then nil # render Component
          when Prism::CallNode then first.name == :new ? nil : :dynamic  # render Comp.new | render method
          else :dynamic                               # render @x / render var (collection/object)
          end
        end

        # "caderneta/_doses.html.erb" → records key "caderneta/doses". Only
        # html/turbo_stream partials become narrowable nodes.
        def record_partial_file(view_relative)
          return unless view_relative =~ %r{/_[^/]+\.(?:html|turbo_stream)\.erb\z}

          stem = File.basename(view_relative).sub(/\.(html|turbo_stream)\.erb\z/, "").sub(/\A_/, "")
          dir = File.dirname(view_relative)
          key = dir == "." ? stem : "#{dir}/#{stem}"
          @partial_files[key] = view_relative
        end

        # "doses" + caller_dir "caderneta" → "caderneta/doses"; already
        # qualified stays; nil when unresolvable without a caller dir.
        def resolve_partial_key(name, caller_dir)
          return name if name.include?("/")
          return nil unless caller_dir

          "#{caller_dir}/#{name}"
        end

        def erb_to_ruby(erb_source)
          require "herb"
          Herb.extract_ruby(erb_source, comments: true)
        end
      end
    end
  end
end
