# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require_relative "callback_chain_scanner"
require_relative "../erb_convention_generator/view_path_naming"
require_relative "../views/template_scanner"

module RbsInfer
  module Extensions
    module Rails
      module Controllers
        # Builds the controller-runtime pseudo-code (felixefelip/rbs_infer#81):
        # plain Ruby that models what Rails does at request time, so the Steep
        # fork can prove — by reading it — what an action may assume on entry.
        #
        # Two kinds of file, both plain `.rb`:
        #
        #   * the FRAMEWORK reopen (`action_controller_base.rb`) — gives
        #     `redirect_to`/`render`/`head` a body that records the halt, and
        #     `performed?` (Rails' own halt predicate) a body that reads it back.
        #     This is the only place the "a callback can abort the chain"
        #     semantics lives.
        #   * one CONTROLLER reopen per controller — a private
        #     `__rbs_infer__run_<action>` per action, holding that action's
        #     effective before_action chain inlined, each link followed by the
        #     halt check, and the action call last; plus (when the controller has
        #     explicit `render :view` calls) a public `render` override that
        #     marks the shared halt marker and dispatches the view symbol to that
        #     view's compiled body.
        #
        # No `.rbs` is emitted: the RBS for these bodies is the analyzer's job
        # (`rbs_infer sig/ --output`), exactly as for any other source. Emitting
        # it here too would declare the same methods twice and RBS rejects that
        # (`Non-overloading method definition of `performed?` … cannot be
        # duplicated`). Everything the pseudo-code declares must therefore be
        # INFERRABLE FROM A BODY — which is why the opaque condition below has
        # one.
        #
        # The controller is REOPENED rather than wrapped in a `Runner` class for
        # two reasons: callbacks are private (an external caller could not invoke
        # them), and everything stays rooted at `self` — which is the shape the
        # Steep fork's contract machinery reasons about best, so ivar narrowing
        # (`@post` set by `set_post`, read by the action) needs no new machinery.
        #
        # The chain is inlined per action instead of factored into a shared
        # `__rbs_infer__run_before_actions_<action>`: facts do not cross a call
        # boundary in the fork today, and every extra hop is machinery someone
        # has to build. Duplication in generated code is free.
        class PseudoCodeBuilder
          # One emitted file: `filename` within the sidecar dir, `source` its
          # full contents.
          FileEntry = Struct.new(:filename, :source, keyword_init: true)

          # Rails halts the before_action chain with its own predicate:
          #
          #   terminator: ->(controller, result_lambda) {
          #     result_lambda.call; controller.performed?
          #   }                       (abstract_controller/callbacks.rb)
          #
          # so `return if performed?` after each link is a transcription of the
          # runtime terminator, not an approximation of it.
          HALTED = "performed?"
          UNKNOWN_CONDITION_METHOD = "__rbs_infer__unknown_condition?"

          # The tool-owned, `bool`-typed ivar that records the halt (see
          # `framework_files`). A single constant so the framework `render`/
          # `redirect_to`/`head`/`performed?` AND the per-controller `render`
          # override all mark/read the SAME marker — the halt semantics have one
          # source, even though (deliberately) modelled in more than one body.
          PERFORMED_IVAR = "@__rbs_infer__performed"

          # The view target is a NAMED leading parameter, and the dispatch cases on it —
          # not `def render(*args)` + `case args.first`.
          #
          # Both spellings type-check the same, but only this one is legible to the fork's
          # argument-sensitive entry facts (felixefelip/steep#89, #91, #95). That machinery
          # partitions a shared dispatcher's facts by the literal each caller passed, and it
          # needs both halves: the producer keys a partition on a named positional parameter
          # (a bare `*args` offers none), and the consumer only correlates a `case` whose
          # subject is a plain read of that parameter (`args.first` is a method call on a
          # local, not a parameter read).
          #
          # With this shape, `render :edit` from an action that ran `set_post` carries
          # `@post` into the `:edit` branch — which is the whole point of the override
          # existing per controller rather than on the framework class.
          RENDER_TARGET_PARAM = "target"


          HEADER = <<~RUBY
            # frozen_string_literal: true
            #
            # GENERATED by RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator.
            # Regenerated on every run; do not edit.
          RUBY

          # app_dir: used to check whether an action's convention view template
          # exists (to emit the view render site). Required — a nil default would
          # silently skip every view render site.
          def initialize(scanner:, app_dir:)
            @scanner = scanner
            @app_dir = app_dir
          end

          # => [FileEntry] (framework reopen first, then one .rb per controller
          # that has at least one action).
          def build
            controllers = @scanner.controllers
            return [] if controllers.empty?

            framework_files + controllers.flat_map { |name| controller_files(name) }
          end

          private

          # Models Rails' own halt mechanism: `redirect_to`/`render`/`head` mark
          # the response as performed, and `performed?` reads that back — which
          # is what the callback terminator calls to stop the chain.
          #
          # The state itself is a TOOL-OWNED, `bool`-typed ivar rather than
          # Rails' real `@_response_body`: state is the only channel a callee
          # (`redirect_to`, often nested inside `respond_to { |f| f.html { … } }`)
          # can use to reach the runner's frame, and only a TYPED ivar can carry
          # a fact — `@_response_body` is declared `untyped`, so refining it
          # would assert nothing.
          #
          # Giving `performed?` a body also re-types it: the analyzer infers
          # `() -> true?` from it, replacing the inherited `() -> untyped`. That
          # is what makes the predicate usable as a proof carrier — testing an
          # `untyped` predicate refines nothing.
          #
          # `(*args)` (no `**kwargs`, which trips a Steep internal error) is
          # permissive enough for every framework signature, and each body ends
          # with a literal `true` so it satisfies the narrowest declared return
          # among them (`head: (...) -> true`).
          #
          # `redirect_to` keeps its FAITHFUL return type (whatever the framework
          # RBS says): modelling the halt as a non-returning `bot` would be both
          # untrue to runtime and useless here, since the halt usually sits inside
          # nested blocks whose bottom-ness would not kill the enclosing call
          # anyway.
          def framework_files
            body = <<~RUBY
              #{HEADER}
              module ActionController
                class Base
                  def redirect_to(*args)
                    #{PERFORMED_IVAR} = true
                    true
                  end

                  def render(*args)
                    #{PERFORMED_IVAR} = true
                    true
                  end

                  def head(*args)
                    #{PERFORMED_IVAR} = true
                    true
                  end

                  def #{HALTED}
                    #{PERFORMED_IVAR}
                  end

                  # Stands for a callback condition we cannot name (a proc taking
                  # the controller, a multi-statement lambda): the link "may or may
                  # not run", so it proves nothing. The body is deliberately an
                  # opaque runtime predicate — the checker can type it (bool) but
                  # never decide it, which is exactly the semantics wanted. It
                  # needs A body at all because the analyzer, not this generator,
                  # emits the RBS.
                  def #{UNKNOWN_CONDITION_METHOD}
                    request.present?
                  end
                end
              end
            RUBY

            [FileEntry.new(filename: "action_controller_base.rb", source: body)]
          end

          def controller_files(class_name)
            actions = @scanner.actions_for(class_name)

            [FileEntry.new(
              filename: "#{filename_for(class_name)}.rb",
              source: controller_source(class_name, actions)
            )]
          end

          def controller_source(class_name, actions)
            runners = actions.map { |action| runner_method(class_name, action) }

            members = []
            members << render_override(class_name)&.chomp
            members << "  private\n\n#{runners.join("\n").chomp}"
            members.compact!

            <<~RUBY
              #{HEADER}
              class #{class_name}
              #{members.join("\n\n")}
              end
            RUBY
          end

          # A per-controller override of `render` modelling an explicit
          # `render :view` (e.g. `create` falling through to `render :new` on a
          # validation failure). It marks the response performed via the SHARED
          # halt marker (`PERFORMED_IVAR`, same one the framework `render` sets),
          # and dispatches on the rendered target to that view's compiled body
          # (`__rbs_infer__body`, felixefelip/steep#85) — so the render's own
          # call-site facts (here, `@post` after a failed `save`) narrow reads in
          # the rendered view.
          #
          # The dispatch lives PER CONTROLLER, not on `ActionController::Base`,
          # on purpose: a view's entry facts are the meet over its call sites, so
          # a single shared dispatch on `Base` would meet EVERY render in the app
          # into every view — the global-collapse we avoid. Each override carries
          # only the targets its own controller renders (its symbols plus any
          # foreign `render "posts/new"` paths), keeping the meet scoped.
          #
          # It cannot `super` into the framework `render`: `super` binds to the
          # REAL Rails `ActionController::Base#render` (returns `String`, and
          # would not set our ivar), so the halt is re-modelled inline against
          # the shared marker instead — one source for the marker NAME, even
          # though two bodies write it.
          #
          # Emitted PUBLIC (before `private`), matching the framework `render` it
          # overrides. Only views whose template exists get a `when`, and the
          # whole method is omitted when none do — the inherited framework
          # `render` then applies unchanged.
          #
          # NOTE: fully consuming this needs the fork to record the render's
          # facts from inside the branch it sits in — a full `if/else` (where the
          # `render :new` lives) and this `case/when` — not just a modifier `if`.
          # That branch-sensitive flow extraction is tracked separately; the
          # pseudo-code is correct regardless — without it the dispatch is inert
          # rather than wrong.
          def render_override(class_name)
            branches = @scanner.render_targets_for(class_name).filter_map do |form, value|
              erb_class, key, view_relative = resolve_render_target(class_name, form, value)
              next unless erb_class

              "    when #{key} then #{view_constructor(erb_class, view_relative)}.__rbs_infer__body"
            end
            return nil if branches.empty?

            [
              "  def render(#{RENDER_TARGET_PARAM} = nil, *rest)",
              "    #{PERFORMED_IVAR} = true",
              "    case #{RENDER_TARGET_PARAM}",
              *branches,
              "    end",
              "    true",
              "  end"
            ].join("\n") + "\n"
          end

          # `[erb_class, case_key]` for a render target, or `[nil, _]` when no
          # template resolves. A symbol (`render :new`) and a bare string
          # (`render "new"`) are controller-relative; a `"dir/view"` string
          # (`render "posts/new"`) is an absolute path that may name another
          # controller's view. The `case_key` is the literal the `when` must
          # match — a symbol for `:new`, a quoted string for `"posts/new"` — so
          # it dispatches on the argument exactly as written at the call site.
          def resolve_render_target(class_name, form, value)
            if form == :symbol
              klass, path = convention_view(class_name, value)
              [klass, ":#{value}", path]
            elsif value.include?("/")
              klass, path = absolute_view(value)
              [klass, value.inspect, path]
            else
              klass, path = convention_view(class_name, value)
              [klass, value.inspect, path]
            end
          end

          # The ERB class of an absolute view path (`"posts/new"` =>
          # `ERBPostsNew`), or nil when no template exists.
          def absolute_view(path)
            fmt = %w[html turbo_stream].find do |f|
              File.exist?(File.join(@app_dir, "app/views", "#{path}.#{f}.erb"))
            end
            return nil unless fmt

            relative = "#{path}.#{fmt}.erb"
            [view_path_naming.erb_class_name(relative), relative]
          end

          # The request flow of one action: every before_action link that runs
          # for it, each followed by the halt check, then the action itself.
          def runner_method(class_name, action)
            lines = @scanner.chain_for(class_name, action).flat_map do |callback|
              link_lines(callback) + ["return if #{HALTED}", ""]
            end

            body = (lines + [action] + view_render_lines(class_name, action))
                     .map { |line| line.empty? ? "" : "    #{line}" }

            ["  def __rbs_infer__run_#{action}", *body, "  end"].join("\n") + "\n"
          end

          # After the action, model Rails' implicit convention render: unless the
          # action already responded (`redirect_to`/explicit `render`/`head` set
          # `performed?`), it renders `action`'s view. Calling the view's
          # compiled-method body (`__rbs_infer__body`, felixefelip/steep#85) at
          # this point — where the guard chain's facts hold — lets those facts
          # narrow reads in the view. The `return if performed?` before it makes
          # the redirect / explicit-render case a no-op automatically. Empty when
          # the action has no convention template.
          def view_render_lines(class_name, action)
            erb_class, view_relative = convention_view(class_name, action)
            return [] unless erb_class

            ["", "return if #{HALTED}", "", "#{view_constructor(erb_class, view_relative)}.__rbs_infer__body"]
          end

          # The ERB class of `action`'s convention template, or nil when none
          # exists. `PostsController#show` → `posts/show.html.erb` → `ERBPostsShow`.
          def convention_view(class_name, action)
            view_dir = class_name.sub(/Controller\z/, "").underscore
            return nil if view_dir.empty?

            fmt = %w[html turbo_stream].find do |f|
              File.exist?(File.join(@app_dir, "app/views", view_dir, "#{action}.#{f}.erb"))
            end
            return nil unless fmt

            relative = "#{view_dir}/#{action}.#{fmt}.erb"
            [view_path_naming.erb_class_name(relative), relative]
          end

          # `ERBPostsShow.new(comments: @comments, post: @post)` — the view's
          # constructor call carrying the ivars ITS TEMPLATE READS, which are the
          # keywords the view-runtime pseudo-code declares on `initialize`.
          #
          # Passing them is what gives those parameters a type at all: the
          # analyzer reads this call site, so the action's `@post` — narrowed by
          # the guard chain emitted above — flows into the view, and from the
          # view's `render` into every partial it constructs. Without arguments
          # the view's ivars infer `untyped` and so does every partial local.
          def view_constructor(erb_class, view_relative)
            ivars = view_ivars(view_relative)
            return "#{erb_class}.new" if ivars.empty?

            "#{erb_class}.new(#{ivars.map { |n| "#{n}: @#{n}" }.join(", ")})"
          end

          def view_ivars(view_relative)
            return [] unless view_relative

            path = File.join(@app_dir, "app/views", view_relative)
            return [] unless File.exist?(path)

            Views::TemplateScanner.scan(File.read(path)).ivars
          end

          def view_path_naming
            @view_path_naming ||= Object.new.extend(ErbConventionGenerator::ViewPathNaming)
          end

          # A handler link is a self-send; a block link is the block's body
          # inlined verbatim (it runs in the controller instance's context, so
          # it is valid there as written).
          def link_lines(callback)
            condition = condition_for(callback)

            if callback.kind == :block
              block_lines(callback, condition)
            elsif condition
              ["#{callback.handler} if #{condition}"]
            else
              [callback.handler]
            end
          end

          def block_lines(callback, condition)
            body = callback.block_source.to_s.lines.map(&:strip).reject(&:empty?)
            return [] if body.empty?

            return body unless condition

            ["if #{condition}", *body.map { |line| "  #{line}" }, "end"]
          end

          # `if:` / `unless:` become a literal Ruby condition — this is where the
          # pseudo-code approach earns its keep: the Steep fork resolves the
          # predicate itself (`authenticated_account_access?` is just a call),
          # with no need to statically prove the condition here.
          def condition_for(callback)
            parts = []
            parts << predicate(callback.if_cond) if callback.if_cond
            parts << "!#{predicate(callback.unless_cond)}" if callback.unless_cond
            return nil if parts.empty?

            parts.join(" && ")
          end

          def predicate(cond)
            cond == Controllers::UNKNOWN_CONDITION ? UNKNOWN_CONDITION_METHOD : cond
          end

          def filename_for(class_name)
            class_name.gsub("::", "_").underscore
          end
        end
      end
    end
  end
end
