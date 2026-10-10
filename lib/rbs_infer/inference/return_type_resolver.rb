module RbsInfer::Inference
  # Resolve return types de métodos a partir de análise estática do corpo dos
  # métodos, via chain resolution e Steep. Os tipos de instance variables ficam
  # com `IvarTypeInferrer`.
  class ReturnTypeResolver
    include KnownReturnTypesBuilder

    def initialize(target_file:, target_class:, method_type_resolver:, instance_types: [], steep_bridge: nil)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @instance_types = instance_types
      @steep_bridge = steep_bridge
    end

    # What the Steep passes share: the kind-split map of Steep's answers, the
    # target they were read from, and the names that read as `self`.
    SteepPass = Struct.new(:steep_returns, :parsed_target, :self_types)

    def improve_method_return_types(members, attr_types, parsed_target: nil)
      return unless parsed_target

      # Métodos com return type untyped — inclui `:method` (instance) e
      # `:class_method` (singleton, `def self.X`) porque o steep_bridge
      # devolve tipos pra ambos via `typing.each_typing` sem distinguir.
      untyped_methods = members.select { |m| method_member?(m) && m.signature =~ /->\ s*untyped$/ }
      return if untyped_methods.empty?

      # Kind-split so a `def self.x` reads Steep's singleton-method type, not a
      # homonymous `def x`'s (felixefelip/rbs_infer#33). Read HERE, before the
      # declarations are applied, because the loop below has to know whether the
      # body disagrees with the declaration it is about to write.
      steep_returns = if @steep_bridge && parsed_target.source
                        @steep_bridge.method_return_types_by_kind(parsed_target.source)
                      end

      deferred_to_body = apply_declared_return_types(untyped_methods, members, attr_types, parsed_target, steep_returns)
      refine_from_steep(members, parsed_target, steep_returns) if steep_returns

      # A deferred declaration is applied after all if the pass above declined the
      # body anyway (a `nil` from a conditional tail is the one shape it refuses
      # to take). Deferring can then cost nothing: the member ends where it would
      # have started.
      deferred_to_body.each do |m, resolved|
        next unless m.signature =~ /->\s*untyped$/

        apply_return_type(m, resolved)
      end
    end

    # Whether the file being analyzed writes this method's body itself — the
    # question that decides whether a same-named DECLARATION describes it or
    # merely precedes it. `def_map` is the expanded target's own defs, so a body
    # spliced in from an `included do` counts as this class's, which is where
    # fizzy's `Card#should_check_mentions?` is written.
    def defines_own_body?(member, parsed_target)
      return false unless parsed_target

      return false unless def_map(parsed_target).key?(member.name)

      # …and the file writes exactly ONE body under that name and kind. Steep's
      # map is keyed by name (kind-split, never owner-split), so two classes
      # declared in one file with a same-named method share one entry and the
      # answer belongs to whichever the typing recorded last — which is how
      # `Example65::Dispatcher.dispatch` reads `Example65::Rival`, the defect
      # example65's own comment records. Where the map cannot say WHOSE body it
      # typed, the declaration is still the better answer.
      file_def_counts(parsed_target)[[member.name, member.kind == :class_method]] == 1
    end

    # Whether Steep's type for this body is one the declaration cannot accept —
    # the `Ruby::MethodBodyTypeMismatch` the checker would report on the emitted
    # RBS, asked before emitting it. Only a decided `false` counts: `accepts?`
    # answers `nil` where it cannot compare, and "we don't know" is not a reason
    # to drop a declaration.
    #
    # Nilability is deliberately IN scope here, unlike the correction pass at the
    # end of this method (felixefelip/rbs_infer#191), which widens the declared
    # type by nil before comparing. That pass revisits a type THIS run already
    # decided, where a lone `T?` from Steep is more likely our own postconditions
    # not being in the store yet than the declaration being wrong. Here nothing
    # has been decided: the choice is between a foreign declaration and the body,
    # and the body is the one this class actually has.
    def body_contradicts?(member, declared, steep_returns)
      return false unless steep_returns

      steep_type = steep_return_for(member, steep_returns)
      return false unless steep_type && steep_type != "untyped" && steep_type != "bot"
      # `nil` says nothing: a conditional tail whose value branch is `untyped`
      # collapses to it, which is why the pass below distrusts it too.
      return false if steep_type == "nil"

      @steep_bridge.accepts?(declared, steep_type) == false
    end

    # name+singleton? => how many defs the WHOLE file writes under it. Flat on
    # purpose (no `target_class`): the collision that matters is the one in
    # Steep's map, which is built from the whole source.
    def file_def_counts(parsed_target)
      @file_def_counts ||= begin
        collector = RbsInfer::AST::DefCollector.new
        parsed_target.tree.accept(collector)
        collector.defs.each_with_object(Hash.new(0)) do |d, counts|
          next unless d.is_a?(Prism::DefNode)

          counts[[d.name.to_s, collector.class_method?(d)]] += 1
        end
      end
    end

    def apply_return_type(member, type)
      member.signature = member.signature.sub(
        /-> untyped$/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(type)}"
      )
    end

    # A bare `return` (or `return nil`) yields nil, so nil belongs in the return union
    # however the rest of the body was typed. Several passes substitute a return type
    # (chain resolution here, Steep here, TypeMerger's tail-call passes after), and only
    # the Steep ones widened — so `return if performed?` followed by a CALL came out
    # `-> bool`, for a body that plainly returns nil on the guard. A literal tail was
    # right only by accident, because it happened to take the Steep path.
    #
    # Applied ONCE, after every pass that can set a return type, rather than at each
    # substitution site: the widening depends only on the body, so it is a property of
    # the finished signature, and spreading it over the passes is how three of them came
    # to disagree in the first place.
    def apply_early_return_nilability(members, parsed_target: nil)
      return unless parsed_target

      members.each do |m|
        next unless method_member?(m)
        # `initialize` is `-> void` by convention, so it is not the body's tail type
        # and not ours to widen. A setter's IS: `obj.x = v` evaluating to `v` is a
        # property of the assignment operator, which discards the method's return —
        # the declaration describes what `super` gets, which is the body
        # (felixefelip/rbs_infer#287).
        next if m.name == "initialize"

        current = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next if current.nil? || current == "untyped" || current == "void" || current.end_with?("?")

        defn = def_map(parsed_target)[m.name]
        next unless defn && has_nil_return?(defn, dead_ranges: dead_ranges(parsed_target))

        m.signature = m.signature.sub(/-> #{Regexp.escape(current)}\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.nilablize(current)}")
      end
    end

    private

    attr_reader :method_type_resolver

    # Aplicar tipos já resolvidos pelo resolver (ex: chamadas a métodos herdados)
    #
    # `known_return_types` is keyed by NAME alone, and for a method THIS FILE
    # defines the name resolves to a DECLARATION — the module's, the
    # superclass's, or this class's own from the previous run. A declaration is
    # not evidence about a body, and an override is exactly where the two part
    # ways: `Example66#relevant?` overrides a template method declared
    # `() -> bool` with a body that reads a nilable accessor, so the honest
    # answer is `bool?`. Applying the declaration here also SETTLES it — the
    # member stops being `untyped`, so the Steep pass below, which reads the
    # body and says `bool?`, is never asked — and the wrong answer is then a
    # fixed point, because the next run reads it back off this class's own RBS
    # (`MethodTypeResolver#build_class_types` step 6). Fizzy's
    # `Card#should_check_mentions?` sat there: emitted `() -> bool` against a
    # body Steep types `(bool | nil)`, through every `--max-passes`.
    #
    # So where the file writes the body and Steep says the declaration does not
    # ACCEPT what that body returns, the declaration is deferred: the member
    # stays `untyped` into the pass below and is typed from the body, with every
    # refinement that pass applies. Everything else — a member with no def here,
    # a body Steep could not type, a body the declaration does accept — takes the
    # declaration exactly as before, which is what keeps a declaration's own
    # spelling (`::Post`, `T?` over `(T | nil)`) from churning across a whole
    # `sig/` for a type that did not change.
    #
    # Returns the deferred `[member, declaration]` pairs.
    def apply_declared_return_types(untyped_methods, members, attr_types, parsed_target, steep_returns)
      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver,
                                                                         target_class: @target_class, instance_types: @instance_types)
      # A class method resolves against its OWN surface. The map above is
      # built from instance members, so applying it to a `:class_method`
      # would leak a homonymous instance method's return type onto it (and
      # the reverse, via the name-keyed Steep map below) —
      # felixefelip/rbs_infer#33.
      class_return_types = build_class_method_return_types(members, method_type_resolver: method_type_resolver,
                                                                    target_class: @target_class)

      untyped_methods.each_with_object([]) do |m, deferred_to_body|
        next if m.name == "initialize"
        # Skipped for the map, not for being a setter: `known_return_types` is
        # keyed by NAME alone — no owner, no kind — so resolving a setter here
        # would leak a colliding setter's return (a CurrentAttributes override
        # onto the generated module accessor) — felixefelip/rbs_infer#22. The
        # Steep pass below has no such skip: its map is kind-split (#33) and it
        # reads each def's own body, which is what a setter returns
        # (felixefelip/rbs_infer#287).
        next if setter_name?(m.name)

        resolved = return_types_for(m, known_return_types, class_return_types)[m.name]
        next unless resolved && resolved != "untyped"

        if defines_own_body?(m, parsed_target) && body_contradicts?(m, resolved, steep_returns)
          deferred_to_body << [m, resolved]
          next
        end

        apply_return_type(m, resolved)
      end
    end

    # Use Steep for any remaining untyped methods, then revisit the typed ones:
    # each pass after the first refines one slice of declaration Steep's reading
    # of the body says more about. Order matters — each pass reads the
    # signatures the previous ones wrote.
    def refine_from_steep(members, parsed_target, steep_returns)
      return if steep_returns[:instance].empty? && steep_returns[:singleton].empty?

      pass = SteepPass.new(steep_returns, parsed_target, Set.new([@target_class] + @instance_types))
      fill_untyped_from_steep(members, pass)
      correct_block_generics(members, pass)
      narrow_proven_non_nil(members, pass)
      refine_untyped_records(members, pass)
      refine_to_self(members, pass)
      refine_literals(members, pass)
      correct_contradicted_declarations(members, pass)
    end

    def fill_untyped_from_steep(members, pass)
      revisable_members(members).each do |m|
        next unless m.signature =~ /->\s*untyped$/

        # `nil` is a genuine inference, not a fallback: the env is built with
        # `implicitly_returns_nil: false`, so Steep types a body as `nil` only
        # when it evaluates to nil. Emitting `-> nil` is precise and keeps a
        # genuinely nil-returning method (e.g. a `class_methods` def whose body
        # is `scope.find_each { … }`) from being stuck at `untyped`
        # (felixefelip/rbs_infer#60). `untyped`/`bot` stay filtered: the former
        # carries no information, the latter means an unreachable/error body.
        steep_type = steep_answer(m, pass, allow_nil: true) or next

        # …but a `nil` from a *conditional* tail is not safe to emit: an
        # `if`/`unless`/`case` whose value branch is `untyped` makes Steep
        # collapse `untyped | nil` to `nil`, so `-> nil` would hide that
        # branch (e.g. `posts.destroy_all if cond`, where `destroy_all` is
        # `untyped`). Only take `nil` from an unconditional tail; otherwise
        # leave the method `untyped` (the honest answer).
        next if steep_type == "nil" && !unconditional_nil_tail?(def_map(pass.parsed_target)[m.name])

        # Instance methods returning the same class (or host class for concerns) → self
        steep_type = "self" if self_return?(m, steep_type, pass.self_types)
        steep_type = with_early_nil_return(m, steep_type, pass)
        rewrite_return(m, "untyped", RbsInfer::Signatures::RbsParserUtil.parenthesize_union(steep_type))
      end
    end

    # Correct already-typed methods where Steep detected BlockBodyTypeMismatch
    # (existing RBS had wrong type from previous generation)
    def correct_block_generics(members, pass)
      revisable_members(members).each do |m|
        next if m.signature =~ /->\s*untyped$/

        steep_type = steep_answer(m, pass) or next
        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next if current_type == steep_type
        # Only override Array types (block generic correction)
        next unless current_type&.start_with?("Array[") && steep_type.start_with?("Array[")

        rewrite_return(m, current_type, steep_type)
      end
    end

    # Narrow an already-inferred nilable return to Steep's non-nil type when
    # Steep — with the postcondition / method-entry facts applied — proves the
    # body can't return nil (e.g. `Foo.name.upcase` where a method-entry fact
    # makes `Foo.name` non-nil at the callee's entry, felixefelip/steep#78).
    # The first pass only upgrades `-> untyped`; this handles `T?` -> `T`.
    # Restricted to a strict `nilablize(steep) == current` match, so an
    # unrelated Steep type can never clobber a good signature, and skipped when
    # the body has an explicit `nil` return (then nilable is the honest answer).
    def narrow_proven_non_nil(members, pass)
      revisable_members(members).each do |m|
        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next unless current_type&.end_with?("?")

        steep_type = steep_answer(m, pass) or next
        next if steep_type == current_type
        next unless RbsInfer::Signatures::RbsParserUtil.nilablize(steep_type) == current_type
        next if early_nil_return?(m, pass)

        steep_type = "self" if self_return?(m, steep_type, pass.self_types)
        rewrite_return(m, current_type, steep_type)
      end
    end

    # Refine record types containing untyped values using Steep's body type inference
    def refine_untyped_records(members, pass)
      revisable_members(members).each do |m|
        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next unless current_type&.start_with?("{") && current_type.include?("untyped")

        steep_type = steep_answer(m, pass) or next
        next unless steep_type.start_with?("{")
        next if current_type == steep_type

        steep_type = "self" if self_return?(m, steep_type, pass.self_types)
        rewrite_return(m, current_type, with_early_nil_return(m, steep_type, pass))
      end
    end

    # A fourth slice, and the one the others cannot reach: the declaration
    # is not vague and not contradicted — it is the TARGET CLASS where the
    # body says `self`. Steep already answers `"self"` here; the general
    # case below leaves it because `Object` genuinely accepts `self`, and
    # the first pass never sees it because the method is already typed.
    #
    # `self` is strictly more precise, and on a base class the difference
    # is the whole answer: `Object#extend` written as `-> Object` throws
    # away what `(*Module) -> self` says, so `base.extend(Foo)` inside a
    # module stops being a `Module` (felixefelip/rbs_infer#302).
    #
    # `self_types` rather than the target class alone, and `self_return?`
    # rather than a bare comparison, so a setter and a class method are
    # excluded for the reasons stated there.
    def refine_to_self(members, pass)
      revisable_members(members).each do |m|
        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next unless self_return?(m, current_type, pass.self_types)
        next unless steep_return_for(m, pass.steep_returns) == "self"

        rewrite_return(m, current_type, "self")
      end
    end

    # A fifth slice: the declaration is right and the body satisfies it,
    # but the body fixes the VALUE — `call(flag_name: true)` returns
    # `"name_delete"` where `call` is declared `-> String`
    # (felixefelip/rbs_infer#345). The general case below cannot reach it,
    # because a `String` never rejects its own literals.
    def refine_literals(members, pass)
      revisable_members(members).each do |m|
        next unless defines_own_body?(m, pass.parsed_target)

        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next unless current_type && current_type != "untyped"

        steep_type = steep_answer(m, pass) or next
        next if steep_type == current_type
        next unless @steep_bridge.literal_refinement?(current_type, steep_type)

        steep_type = with_early_nil_return(m, steep_type, pass)
        rewrite_return(m, current_type, RbsInfer::Signatures::RbsParserUtil.parenthesize_union(steep_type))
      end
    end

    # The general case the passes above each cover a slice of: the
    # declared return does not ACCEPT the type Steep gives the body, which
    # is the `Ruby::MethodBodyTypeMismatch` the checker reports on the
    # generated RBS. Those refine a declaration that is merely imprecise
    # (a block's `Array[untyped]`, a nilable Steep proves non-nil, a record
    # with `untyped` values, a class name where the body says `self`) — all
    # of them types the body still satisfies.
    # Nothing revisited a declaration the body CONTRADICTS.
    #
    # Without this, a return type is a ratchet: the first pass only fills
    # `-> untyped`, so once a concrete type is written it survives every
    # regeneration, including after the type it was derived from changes
    # underneath it. Fizzy's `FilterScoped#set_filter` was emitted as
    # `-> (Filter & Filter::Validated)`, then `Filter.from_params` widened
    # to `((Filter & Filter::Validated) | Array[Filter])` when
    # `ActiveRecord::Relation#build` gained its Array overload — and the
    # regeneration that widened `@filter` (recomputed every run) left the
    # return alone, so the error was permanent
    # (felixefelip/rbs_infer#191).
    #
    # Only a decided `false` corrects: `accepts?` answers `nil` where it
    # cannot compare, and "we don't know" must not overwrite a signature.
    def correct_contradicted_declarations(members, pass)
      revisable_members(members).each do |m|
        current_type = RbsInfer::Signatures::RbsParserUtil.return_type_of(m.signature)
        next unless current_type && current_type != "untyped"

        # `nil` stays out for the reason the first pass distrusts it: a
        # conditional tail whose value branch is `untyped` collapses to
        # `nil`, which says nothing about what the method returns.
        steep_type = steep_answer(m, pass) or next

        steep_type = "self" if self_return?(m, steep_type, pass.self_types)
        steep_type = with_early_nil_return(m, steep_type, pass)
        next if steep_type == current_type
        # Compared against the declared type WIDENED BY NIL, so a body that
        # differs from it only by nilability is left alone. That axis is the
        # one where the rest of the pipeline knows more than Steep does
        # here: the postcondition/narrowing facts that prove an ivar or
        # accessor non-nil are generated by the same run and are not in the
        # store yet, so an isolated `T?` on a declaration of `T` is our fact
        # missing, not the declaration being wrong — which is exactly what
        # the pass above exists to encode in the other direction.
        next unless @steep_bridge.accepts?(
          RbsInfer::Signatures::RbsParserUtil.nilablize(current_type), steep_type
        ) == false

        rewrite_return(m, current_type, RbsInfer::Signatures::RbsParserUtil.parenthesize_union(steep_type))
      end
    end

    # The members a Steep pass may revisit: methods, never `initialize`.
    def revisable_members(members)
      members.select { |m| method_member?(m) && m.name != "initialize" }
    end

    # Steep's type for this member's body, or nil where it says nothing:
    # `untyped` carries no information and `bot` is an unreachable/error body.
    # `nil` only where the caller can tell a real nil from a collapsed one.
    def steep_answer(member, pass, allow_nil: false)
      steep_type = steep_return_for(member, pass.steep_returns)
      return if steep_type.nil? || %w[untyped bot].include?(steep_type)
      return if steep_type == "nil" && !allow_nil

      steep_type
    end

    def early_nil_return?(member, pass)
      defn = def_map(pass.parsed_target)[member.name]
      defn && has_nil_return?(defn, dead_ranges: dead_ranges(pass.parsed_target))
    end

    # Check for early return nil in body
    def with_early_nil_return(member, type, pass)
      early_nil_return?(member, pass) ? RbsInfer::Signatures::RbsParserUtil.nilablize(type) : type
    end

    def rewrite_return(member, from, to)
      member.signature = member.signature.sub(/-> #{Regexp.escape(from)}$/, "-> #{to}")
    end

    # `user=`-style writer (not `==`/`<=`/`[]=` operators).
    def setter_name?(name)
      name.to_s.match?(/[A-Za-z0-9_]=\z/) && !name.to_s.start_with?("[")
    end

    # Singleton (`def self.X`) é coletado como `:class_method` em
    # `class_member_collector.rb` mas tem o mesmo tratamento de inferência de
    # retorno que `:method` (steep_bridge devolve por nome para ambos).
    def method_member?(member)
      %i[method class_method].include?(member.kind)
    end

    # Pick the return-type map matching a member's kind so instance and
    # class methods never read each other's types (felixefelip/rbs_infer#33).
    def return_types_for(member, instance_map, class_map)
      member.kind == :class_method ? class_map : instance_map
    end

    # Same selection for the kind-split Steep map (`{instance:, singleton:}`).
    # What Steep gave this member's own body: by receiver kind, and by the
    # module that owns it — the target, or the module the member sits in
    # inside it (`ReturnTable`).
    def steep_return_for(member, steep_returns)
      table = member.kind == :class_method ? steep_returns[:singleton] : steep_returns[:instance]
      owner = [@target_class&.delete_prefix("::"), member.owner].compact.join("::")
      table.lookup(owner, member.name)
    end

    # Whether a body typed `steep_type` should be emitted as RBS `self`.
    #
    # Only for instance methods. In RBS `self` is the type of the receiver, so
    # in a singleton method it means `singleton(Klass)` — NOT an instance. A
    # `def self.instance; @instance ||= Klass.new; end` returns an instance, so
    # emitting `self` there declares a type the body doesn't have, and Steep
    # rejects it: "Cannot allow method body have type `::Klass` because
    # declared as type `self`". Mirrors the `own_kind != :class_method` guard
    # in TypeMerger (felixefelip/rbs_infer#33/#34).
    def self_return?(member, steep_type, self_types)
      # Never for a setter, whatever its body evaluates to. `self` is the
      # RECEIVER, and a setter returns neither the receiver nor — on the one
      # path that observes it, `super` — anything the receiver's identity
      # implies: `def user=(v); @user = v; end` on a `Widget` hands `super`'s
      # caller the assigned `Widget`, not the `Widget` it was called on
      # (felixefelip/rbs_infer#287).
      return false if setter_name?(member.name)

      member.kind != :class_method && self_types.include?(steep_type)
    end

    # Method name → its `Prism::DefNode`, for the passes that need to read a body back
    # (early-return detection). Memoized per target: both the chain-resolution pass and
    # the Steep pass ask, and collecting is a full tree walk.
    def def_map(parsed_target)
      @def_map ||= begin
        collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
        parsed_target.tree.accept(collector)
        collector.defs.each_with_object({}) do |d, map|
          map[d.name.to_s] = d if d.is_a?(Prism::DefNode)
        end
      end
    end

    # Verifica se o corpo do método contém `return nil` ou `return` (implícito nil)
    def has_nil_return?(defn, dead_ranges:)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        # A `return` that cannot run says nothing about what the method returns.
        # `return if current_user.nil?`, written under a guard that already
        # established `current_user`, reads as dead code to a human — and Steep,
        # which computed exactly that, reports the branch as unreachable. Counting
        # it made a method that never returns nil come out `T?`, and every fact
        # downstream of that type went with it (felixefelip/rbs_infer#286).
        next false if dead_ranges.any? { |range| range.cover?(node.location.start_offset) }

        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
    end

    # The dead branches of the target's source, memoized per target the way
    # `def_map` is: all five passes above ask, and the answer is one type-check
    # away. Empty without a bridge or a source — the honest "nothing proved
    # dead", which leaves every `return` counted exactly as before.
    def dead_ranges(parsed_target)
      @dead_ranges ||=
        if @steep_bridge && parsed_target&.source
          @steep_bridge.unreachable_branch_ranges(parsed_target.source)
        else
          []
        end
    end

    # Conditional tail expressions (`if`/`unless`/`case` — including the
    # modifier forms, which Prism parses as the same nodes) implicitly yield
    # `nil` from a missing/empty branch. When the value branch is `untyped`,
    # Steep collapses `untyped | nil` to `nil`, so a `nil` inference there does
    # NOT mean the method only ever returns nil. `true` only when the def's tail
    # statement is something else (a call, literal, iterator, …) — i.e. the body
    # unconditionally evaluates to nil and `-> nil` is safe to emit.
    CONDITIONAL_TAIL_NODES = [Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode].freeze

    def unconditional_nil_tail?(defn)
      return false unless defn

      # `def x; end` has no body node at all: it has no tail to be conditional.
      body = defn.body
      return true if body.nil?
      return false unless body.is_a?(Prism::StatementsNode)

      tail = body.body.last
      return false if tail.nil?

      CONDITIONAL_TAIL_NODES.none? { |klass| tail.is_a?(klass) }
    end
  end
end
