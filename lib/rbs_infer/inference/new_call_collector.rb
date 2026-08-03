module RbsInfer::Inference
  class NewCallCollector < Prism::Visitor
    attr_reader :usages, :method_call_usages, :method_block_returns

    # Collect the fully-qualified names of every class/module DEFINED in a
    # parsed file, so `match_class?` can tell a bare `Foo` written inside
    # `Example3` (→ `Example3::Foo`) apart from a same-named class elsewhere
    # (`Example2::Foo`). Order-independent: gathered up front, not during the
    # main call-collecting traversal.
    def self.collect_defined_class_names(root_node)
      names = Set.new
      stack = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)
        pushed = nil
        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
          if segment
            pushed = stack.empty? ? segment : "#{stack.last}::#{segment}"
            names << pushed
            stack.push(pushed)
          end
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
        stack.pop if pushed
      end
      walk.call(root_node)
      names
    end

    def initialize(target_class:, method_return_types:, local_var_types:, constant_arg_resolver:, defined_class_names:, local_var_read_types: {}, local_var_types_by_method: {}, method_type_resolver: nil, caller_class_name: nil, init_positional_params: [], target_methods: {}, match_bare_calls: false, self_types_by_method: {}, module_self_types: {}, established_ivars_by_method: {}, argument_partitions_by_method: {}, block_methods: Set.new, expression_types: {}, method_owners: {})
      @target_class = target_class
      # FQNs of classes/modules defined in the file being scanned; disambiguates
      # a relative receiver from a same-simple-name class elsewhere (see
      # `match_class?`). Required (required-threaded-deps): a forgotten wire
      # silently re-enables the cross-class conflation this guards against.
      @defined_class_names = defined_class_names
      @method_return_types = method_return_types
      @local_var_types = local_var_types
      # Steep's type AT each local-variable read, keyed by [line, column]. The
      # map above is a scratchpad this collector MUTATES to model flow (it
      # stores ivars in there too); this one is a fact about a position, so it
      # answers first and the scratchpad remains the fallback
      # (felixefelip/rbs_infer#142).
      @local_var_read_types = local_var_read_types
      # Locals keyed by the method they belong to. `local_var_types` above is
      # flattened across the whole file, first-wins, so a name used in two
      # methods carries ONE type — and the wrong method's, at that
      # (felixefelip/rbs_infer#142). Entering a `def` swaps the file-wide names
      # for that method's own; a source with no `def` at all (an ERB template
      # is one method's body) keeps the flat map, which is all it ever had.
      @local_var_types_by_method = local_var_types_by_method
      @method_scoped_var_names = local_var_types_by_method.each_value.flat_map(&:keys).to_set
      @method_type_resolver = method_type_resolver
      @caller_class_name = caller_class_name
      # Required: omitting it silently re-emits the invalid bare-constant
      # form this fixes (#46, required-threaded-deps).
      @constant_arg_resolver = constant_arg_resolver
      @init_positional_params = init_positional_params
      @target_methods = target_methods
      @match_bare_calls = match_bare_calls
      # `{ "method_name" => "Self & Self::Validated" }` — refined `self`
      # types per method, from after-validation callback sidecars (see
      # SteepBridge#callback_self_types). Preferred over the lexical class
      # name when resolving `self` inside such a method.
      @self_types_by_method = self_types_by_method
      # `{"Card::Entropic" => "(Card & Card::Entropic)"}` — what each module's
      # INSTANCE methods see as `self`, from the self-type annotators. Keyed by
      # module, because one file can declare several and they have different
      # includers (felixefelip/rbs_infer#165).
      @module_self_types = module_self_types
      # `{ "set_post" => { "@post" => "(::Post & ::Post::Validated)" } }` — ivars a
      # self-method proves populated once it has run (postconditions sidecar). Applied
      # in source order by `visit_call_node`, so only call sites AFTER the establishing
      # call see the narrowed type (felixefelip/rbs_infer#109).
      @established_ivars_by_method = established_ivars_by_method
      # `{ "render" => [{ param:, pattern:, ivars: }] }` — argument-sensitive partitions
      # (felixefelip/steep#89, #91, #95). Applied per `when` branch by `visit_case_node`.
      @argument_partitions_by_method = argument_partitions_by_method
      # felixefelip/rbs_infer#155: names whose signature carries a block, and
      # Steep's types for this file, so a call site can be asked what the block
      # it passes returns. Empty when the caller is analyzed without a bridge.
      # felixefelip/rbs_infer#159: `{ "deny" => "Example19::Responder" }` — the
      # target's methods that belong to a nested module, which is emitted in
      # place rather than as a target of its own, so its call sites are matched
      # against the OWNER's name instead of the enclosing target's.
      @method_owners = method_owners
      @block_methods = block_methods
      @expression_types = expression_types
      @usages = []
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
      @method_block_returns = Hash.new { |h, k| h[k] = [] }
      # Lexically-enclosing class names (fully qualified) and whether the
      # current method is a singleton (`def self.x`) — used to resolve a
      # `self` argument/receiver to its type.
      @class_name_stack = []
      # `:class` / `:module` for each enclosing declaration, innermost last. A
      # module's `self` is whoever includes it, so an instance method there
      # cannot claim the module's name (felixefelip/rbs_infer#159).
      @declaration_kinds = []
      # Enclosing MODULE names, innermost last — only to tell which module the
      # annotators' self-type answer was about.
      @module_name_stack = []
      @in_singleton_method = false
      @current_method = nil
    end

    # A module declaration does not push a name — `@class_name_stack` is about
    # the enclosing CLASS — but it does decide what `self` is inside it.
    def visit_module_node(node)
      @declaration_kinds.push(:module)
      @module_name_stack.push(module_name_for(node))
      super
    ensure
      @declaration_kinds.pop
      @module_name_stack.pop
    end

    # A module's FQN, joined with whatever encloses it. Tracked apart from
    # `@class_name_stack`, which modules deliberately stay out of — a module
    # name is not a `self` type, and the only thing this answers is WHICH module
    # the annotators' answer was about (felixefelip/rbs_infer#161).
    def module_name_for(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path) or return nil
      outer = @module_name_stack.last || @class_name_stack.last

      outer ? "#{outer}::#{segment}" : segment
    end

    def visit_class_node(node)
      @declaration_kinds.push(:class)
      # Pré-coletar tipos de ivars de todos os métodos da classe
      # para que @post definido em set_post esteja disponível em publish
      collect_class_ivar_types(node)

      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      full_name =
        if segment
          @class_name_stack.empty? ? segment : "#{@class_name_stack.last}::#{segment}"
        end
      @class_name_stack.push(full_name) if full_name
      super
      @class_name_stack.pop if full_name
      @declaration_kinds.pop
    end

    def visit_def_node(node)
      old_vars = @local_var_types.dup
      old_singleton = @in_singleton_method
      old_method = @current_method
      # `def self.foo` carries a receiver; plain `def foo` does not.
      @in_singleton_method = !node.receiver.nil?
      @current_method = node.name.to_s
      unless @method_scoped_var_names.empty?
        @local_var_types = @local_var_types.reject { |name, _| @method_scoped_var_names.include?(name) }
        @local_var_types.merge!(@local_var_types_by_method[@current_method] || {})
      end
      collect_local_assignments(node)
      super
      @current_method = old_method
      @in_singleton_method = old_singleton
      @local_var_types = old_vars
    end

    # A `case <param> ... when <literal>` branch is reachable only for callers who passed
    # that literal, so the facts the fork recorded for that (param, literal) partition hold
    # inside it — and only inside it. Each branch body is visited with those ivars merged
    # in, then the table is restored, so a sibling branch and everything after the `case`
    # are unaffected.
    #
    # This is what lets a shared dispatcher stay precise: a controller's `render` override
    # is one method reached from every action, so its ivars are the meet over all of them;
    # the partition is what says "on the :edit path, `@post` was established".
    def visit_case_node(node)
      partitions = partitions_for_case(node)
      return super if partitions.empty?

      node.conditions.each do |clause|
        next unless clause.is_a?(Prism::WhenNode)

        ivars = clause.conditions.filter_map { |c| partitions[literal_key(c)] }.reduce({}, :merge)
        if ivars.empty?
          clause.statements&.accept(self)
          next
        end

        saved = @local_var_types.dup
        ivars.each { |name, type| @local_var_types[name] = type }
        clause.statements&.accept(self)
        @local_var_types = saved
      end

      node.else_clause&.accept(self)
      node.predicate&.accept(self)
      nil
    end

    def visit_call_node(node)
      apply_established_ivars(node)

      if node.name == :new && node.receiver
        receiver_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
        if receiver_name && match_class?(receiver_name)
          args = extract_keyword_args(node)
          args.merge!(extract_positional_args(node))
          @usages << args unless args.empty?
        end
      end

      # Cross-class method calls: receiver.method(args) onde receiver é do tipo target_class
      if !@target_methods.empty? && node.receiver && node.arguments
        method_name = node.name.to_s
        if @target_methods.key?(method_name)
          receiver_type = resolve_receiver_type(node.receiver)
          if receiver_type && (match_class?(receiver_type) || owner_match?(receiver_type, method_name))
            args = extract_cross_class_args(node, @target_methods[method_name])
            @method_call_usages[method_name] << args unless args.empty?
          end
        end
      end

      # felixefelip/rbs_infer#155: what the block passed HERE returns. Not gated
      # on `node.arguments` like the branches above — `with_token do |t| … end`
      # passes no arguments at all, and the block is the whole point.
      if !@block_methods.empty? && node.block.is_a?(Prism::BlockNode) && @block_methods.include?(node.name.to_s)
        if node.receiver.nil? ? @match_bare_calls : block_receiver_matches?(node)
          type = BlockReturnCollector.block_return_type(node.block, @expression_types)
          @method_block_returns[node.name.to_s] << type if type
        end
      end

      # Bare method calls matching target_methods (for included modules, e.g. helpers in ERB views)
      if !@target_methods.empty? && node.receiver.nil? && node.arguments && @match_bare_calls
        method_name = node.name.to_s
        if @target_methods.key?(method_name)
          args = extract_cross_class_args(node, @target_methods[method_name])
          @method_call_usages[method_name] << args unless args.empty?
        end
      end

      super
    end

    private

    def block_receiver_matches?(node)
      receiver_type = resolve_receiver_type(node.receiver)
      receiver_type && match_class?(receiver_type)
    end

    # Lookup the type of an `:ivar` reference. Tries the `@`-prefixed
    # key first (the convention used by `ErbCallerResolver` to keep
    # ivar names separate from same-basename local vars), then falls
    # back to the unprefixed key (used by `collect_class_ivar_types`
    # for in-class ivars).
    def lookup_ivar_type(node)
      full = node.name.to_s
      @local_var_types[full] || @local_var_types[full.sub(/\A@/, "")] || declared_ivar_type(full)
    end

    # The type the ENCLOSING class's RBS declares for this ivar
    # (felixefelip/rbs_infer#111).
    #
    # `collect_class_ivar_types` only records an ivar assigned from a CallNode
    # (`@post = Post.new`), so `@post = post` — storing a constructor argument, the
    # commonest shape there is — left the ivar unknown and every call site passing it
    # resolved to `untyped`. The fact was never missing: a previous stabilization pass
    # already wrote `@post: Post` into the class's own RBS. This reads it back rather
    # than teaching the syntactic collector one more assignment shape.
    # Resolved against the LEXICALLY ENCLOSING class, not the file's top-level one:
    # `@caller_class_name` is per-file, so in a file of nested classes it names the
    # outer one, whose RBS declares none of the inner `@x`. Reading the wrong class's
    # declaration would be worse than reading none — two nested classes may each
    # declare `@post` at different types.
    def declared_ivar_type(name)
      return nil unless @method_type_resolver

      class_name = @class_name_stack.last || @caller_class_name
      return nil unless class_name

      type = @method_type_resolver.resolve_ivar_types(class_name)[name]
      type if type && type != "untyped"
    end

    # A self-call to a method whose postcondition establishes ivars narrows them for
    # everything that follows IN THIS BODY. Visiting happens in source order, so
    # recording into `@local_var_types` here is enough to order the effect: a
    # `.new(post: @post)` written before the `set_post` call still sees the declared
    # type. `visit_def_node` saves/restores the table, so the narrowing does not leak
    # into a sibling method.
    #
    # Only a bare (implicit-self) call counts — `other.set_post` writes another
    # object's ivars, not ours.
    def apply_established_ivars(node)
      return if @established_ivars_by_method.empty?
      return unless node.receiver.nil?

      established = @established_ivars_by_method[node.name.to_s] or return
      established.each { |ivar, type| @local_var_types[ivar] = type }
    end

    # `{ literal_key => ivars }` for the partitions keyed on this `case`'s subject, or `{}`.
    # Only a bare read of a METHOD PARAMETER qualifies: the correlation is between the
    # caller's argument and the branch, and a `case` on anything else says nothing about
    # what the caller passed.
    def partitions_for_case(node)
      return {} if @argument_partitions_by_method.empty?
      return {} unless @current_method

      predicate = node.predicate
      return {} unless predicate.is_a?(Prism::LocalVariableReadNode)

      param = predicate.name.to_s
      (@argument_partitions_by_method[@current_method] || []).each_with_object({}) do |partition, acc|
        next unless partition[:param] == param

        acc[partition[:pattern]] = partition[:ivars]
      end
    end

    # The canonical literal string the fork's `Postconditions::LiteralKey` produces, so a
    # `when` pattern here matches the `pattern` recorded there. Both sides must spell the
    # same literal the same way or nothing correlates.
    def literal_key(node)
      case node
      when Prism::SymbolNode then ":#{node.value}"
      when Prism::StringNode then node.unescaped.inspect
      when Prism::IntegerNode, Prism::FloatNode then node.slice
      when Prism::TrueNode then "true"
      when Prism::FalseNode then "false"
      when Prism::NilNode then "nil"
      end
    end

    def collect_class_ivar_types(class_node)
      ivar_writes = RbsInfer::Analyzer.find_all_nodes(class_node) do |n|
        n.is_a?(Prism::InstanceVariableWriteNode) && n.value.is_a?(Prism::CallNode)
      end

      ivar_writes.each do |ivar|
        var_name = ivar.name.to_s.sub(/\A@/, "")
        next if @local_var_types[var_name]

        call = ivar.value
        if call.name == :new && call.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(call.receiver)
          @local_var_types[var_name] = class_name if class_name
        elsif @method_type_resolver
          class_name = RbsInfer::Analyzer.extract_constant_path(call.receiver)
          if class_name
            resolved = @method_type_resolver.resolve_class_method(class_name, call.name.to_s)
            @local_var_types[var_name] = resolved.delete_suffix("?") if resolved && resolved != "untyped"
          end
        end
      end
    end

    def match_class?(name)
      normalized_target = @target_class.sub(/\A::/, "")
      receiver_components(name).any? do |component|
        normalized_name = component.sub(/\A::/, "")
        next true if normalized_name == normalized_target
        relative_receiver_matches_target?(normalized_name, normalized_target)
      end
    end

    # Every nominal type the receiver could hold at the moment of the call.
    #
    # An intersection is the marker-decorated shape (`Caderneta &
    # Caderneta::Validated`) — any component identifies the receiver. A union is
    # every branch the ivar was written with. And `T?` is `T`: the call is being
    # MADE on it, so at runtime it is a `T` or the program raises — the same
    # optimism `MethodTypeResolver#resolve` already applies when it drops the `?`
    # before looking a method up.
    #
    # Decomposing only the intersection is what silently dropped every
    # `Current.<attr>.method(arg)` call site: a CurrentAttributes reader is
    # honestly nilable (per-request reset), so its type arrives as
    # `(Caderneta & Caderneta::Validated)?` and the whole string was compared
    # against `Caderneta` (felixefelip/rbs_infer#131).
    def receiver_components(type_str)
      flatten_receiver_type(RBS::Parser.parse_type(type_str))
    rescue RBS::ParsingError, RBS::BaseError
      # A spelling RBS cannot parse still gets the legacy intersection split, so
      # nothing that matched before stops matching.
      intersection_components(type_str)
    end

    def flatten_receiver_type(type)
      case type
      when RBS::Types::Union, RBS::Types::Intersection
        type.types.flat_map { |t| flatten_receiver_type(t) }
      when RBS::Types::Optional
        flatten_receiver_type(type.type)
      when RBS::Types::Bases::Nil
        []
      else
        [type.to_s]
      end
    end

    # A relative receiver spelling (`Foo`, `Bar::Baz`) matches a target whose
    # full name ends with it (`Email` == `Academico::Aluno::Email`) — the
    # whole-program unique-simple-name assumption the analyzer relies on when
    # the receiver isn't fully qualified.
    #
    # The one exception: two classes sharing a simple name must not be
    # conflated. A bare `Foo` written *inside* `class Example3` is
    # `Example3::Foo` — Ruby resolves it against the lexical nesting — so it
    # must not match target `Example2::Foo`. We can prove this soundly whenever
    # the file being scanned itself defines the class the spelling resolves to:
    # if `Foo` resolves to `Example3::Foo` (a class defined in this file) under
    # the current nesting, it is that class, not the same-named target
    # elsewhere. Absent such a local definition we keep the unique-name
    # assumption (cross-file), which existing behaviour depends on.
    # `Responder.deny(self, "denied")` where `deny` belongs to
    # `Example19::Responder`, a nested MODULE. Such a module is emitted inside
    # its enclosing target's block rather than as a target of its own
    # (felixefelip/rbs_infer#22), so nothing ever asked about its call sites and
    # its parameters stayed `untyped` — while a nested CLASS three lines away,
    # being a target, had everything inferred.
    #
    # The receiver is matched against the OWNER here, not the enclosing target,
    # and only for a method that owner actually has.
    def owner_match?(receiver_type, method_name)
      owner = @method_owners[method_name] or return false

      receiver_components(receiver_type).any? do |component|
        normalized = component.sub(/\A::/, "")
        normalized == owner || relative_receiver_matches_target?(normalized, owner)
      end
    end

    def relative_receiver_matches_target?(relative_name, target)
      return false unless target.end_with?("::#{relative_name}")
      resolved = resolve_relative_in_file(relative_name)
      return false if resolved && resolved != target
      true
    end

    # Ruby-style constant lookup of a relative name against the current lexical
    # nesting, restricted to classes DEFINED IN THIS FILE — the only
    # whole-program-agnostic signal available locally. Walks the nesting
    # innermost-first (`Example3::Foo` before top-level `Foo`) and returns the
    # first candidate this file defines, or nil when the file defines no such
    # class in scope.
    def resolve_relative_in_file(relative_name)
      return nil if @defined_class_names.empty?
      parts = (@class_name_stack.last || @caller_class_name)&.split("::") || []
      parts.length.downto(0) do |i|
        candidate = (parts[0, i] + [relative_name]).join("::")
        return candidate if @defined_class_names.include?(candidate)
      end
      nil
    end

    # Top-level components of an intersection type, respecting [] / ()
    # nesting so generics aren't split: "Caderneta & Caderneta::Validated"
    # → ["Caderneta", "Caderneta::Validated"]. A non-intersection type
    # returns itself. Outer enveloping parens are stripped first.
    def intersection_components(type_str)
      inner = strip_enveloping_parens(type_str.strip)
      components = []
      depth = 0
      buffer = +""
      inner.each_char do |char|
        case char
        when "[", "(" then depth += 1; buffer << char
        when "]", ")" then depth -= 1; buffer << char
        when "&"
          if depth.zero?
            components << buffer.strip
            buffer = +""
          else
            buffer << char
          end
        else buffer << char
        end
      end
      components << buffer.strip
      components.reject(&:empty?)
    end

    # Strips parens only when they envelop the whole string ("(A & B)" → "A &
    # B"); leaves "(A) & (B)" untouched.
    def strip_enveloping_parens(str)
      return str unless str.start_with?("(") && str.end_with?(")")

      depth = 0
      str.each_char.with_index do |char, i|
        depth += 1 if char == "("
        depth -= 1 if char == ")"
        return str if depth.zero? && i < str.length - 1
      end
      str[1..-2].strip
    end

    def collect_local_assignments(defn)
      # Resolver tipos dos parâmetros do método via call-sites
      collect_param_types(defn)

      body = defn.body
      return unless body

      stmts = case body
              when Prism::StatementsNode then body.body
              else [body]
              end

      stmts.each do |stmt|
        if stmt.is_a?(Prism::LocalVariableWriteNode)
          var_name = stmt.name.to_s
          if stmt.value.is_a?(Prism::CallNode)
            if stmt.value.receiver.nil?
              # aluno_dto = build_dto
              method_name = stmt.value.name.to_s
              if @method_return_types[method_name]
                @local_var_types[var_name] = @method_return_types[method_name]
              end
            elsif stmt.value.name == :new && stmt.value.receiver
              # aluno_dto = Academico::Aluno::Matricular::Dto.new(...)
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              @local_var_types[var_name] = class_name if class_name
            elsif @method_type_resolver
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              if class_name
                resolved = @method_type_resolver.resolve_class_method(class_name, stmt.value.name.to_s)
                @local_var_types[var_name] = resolved.delete_suffix("?") if resolved && resolved != "untyped"
              end
            end
          end
        elsif stmt.is_a?(Prism::InstanceVariableWriteNode)
          var_name = stmt.name.to_s.sub(/\A@/, "")
          if stmt.value.is_a?(Prism::CallNode)
            if stmt.value.name == :new && stmt.value.receiver
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              @local_var_types[var_name] = class_name if class_name
            elsif @method_type_resolver
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              if class_name
                resolved = @method_type_resolver.resolve_class_method(class_name, stmt.value.name.to_s)
                @local_var_types[var_name] = resolved.delete_suffix("?") if resolved && resolved != "untyped"
              end
            end
          end
        end
      end
    end

    # Resolver tipos dos parâmetros do método via call-sites do caller class
    # Ex: Entity#initialize(email:) → email é String (inferido dos call-sites de Entity.new)
    # Usa resolve_init_param_types (o que callers passam), NÃO resolve_all (tipos dos attrs)
    # Motivo: param email recebe String, mas attr email é Email (self.email = Email.new(...))
    def collect_param_types(defn)
      return unless @method_type_resolver && @caller_class_name

      # Só resolvo initialize por enquanto (caso mais comum e útil)
      return unless defn.name == :initialize

      init_param_types = @method_type_resolver.resolve_init_param_types(@caller_class_name)
      params = defn.parameters
      return unless params

      if params.respond_to?(:keywords)
        params.keywords.each do |kw|
          name = kw.name.to_s
          type = init_param_types[name]
          @local_var_types[name] = type if type && type != "untyped"
        end
      end

      if params.respond_to?(:requireds)
        params.requireds.each do |p|
          next unless p.respond_to?(:name)
          name = p.name.to_s
          type = init_param_types[name]
          @local_var_types[name] = type if type && type != "untyped"
        end
      end
    end

    def extract_keyword_args(call_node)
      args = {}
      return args unless call_node.arguments

      call_node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)

        arg.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)

          key = extract_symbol_key(elem.key)
          next unless key

          value_type = resolve_value_type(elem.value)
          args[key] = value_type
        end
      end

      args
    end

    def extract_positional_args(call_node)
      args = {}
      return args if @init_positional_params.empty?
      return args unless call_node.arguments

      index = 0
      call_node.arguments.arguments.each do |arg|
        break if index >= @init_positional_params.size
        next if arg.is_a?(Prism::KeywordHashNode)

        param_name = @init_positional_params[index]
        args[param_name] = resolve_value_type(arg)
        index += 1
      end

      args
    end

    def extract_symbol_key(node)
      return node.unescaped if node.is_a?(Prism::SymbolNode)
      nil
    end

    # Steep's type for this particular read, or nil. Prism's character column
    # matches Parser's; the byte column would drift on multibyte source.
    def lvar_read_type(node)
      @local_var_read_types[[node.location.start_line, node.location.start_character_column]]
    end

    def resolve_value_type(node)
      # A hash literal is handled here, ahead of the generic literal inferrer, so its VALUES
      # resolve with what this collector knows — ivars, locals, method returns. The generic
      # inferrer builds the same record shape but sees none of that, so `{ post: @post }`
      # came out `{ post: untyped }` even where `@post` is a known `Post & Post::Validated`.
      return hash_literal_type(node) if record_shaped?(node)

      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, constant_resolver: @constant_arg_resolver)
      return literal if literal

      case node
      when Prism::LocalVariableReadNode
        lvar_read_type(node) || @local_var_types[node.name.to_s] || "untyped"
      when Prism::InstanceVariableReadNode
        lookup_ivar_type(node) || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          refined_self_method_type(node.name.to_s) || @method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          resolve_method_chain(node) || "untyped"
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        resolve_constant_arg_type(node)
      when Prism::SelfNode
        current_self_type
      when Prism::ImplicitNode
        resolve_value_type(node.value)
      else
        "untyped"
      end
    end

    # See ConstantArgTypeResolver (#46).
    def resolve_constant_arg_type(node)
      name = RbsInfer::Analyzer.extract_constant_path(node)
      namespace = @class_name_stack.last || @caller_class_name
      @constant_arg_resolver.resolve(name: name, namespace: namespace) || "untyped"
    end

    # Resolve `self` (passed as an argument or used as a receiver) to the
    # lexically-enclosing class. Inside an instance method `self` is an
    # instance of that class (`Caderneta`); inside a singleton method
    # (`def self.x`) it's the class object itself (`singleton(Caderneta)`),
    # so we never infer a bogus instance type for it. Falls back to the
    # caller class (derived from the file path) when no class node is on
    # the stack, and to `"untyped"` when even that is unknown.
    #
    # Drives call-site inference like `Cadastrar.new(self)` inside
    # `Caderneta#criar_caderneta_de_vacinacao`, where the positional
    # `initialize(caderneta)` param should infer as `Caderneta`.
    def current_self_type
      # Inside an instance method covered by an after-validation callback,
      # `self` is the validated record — prefer the refined type from the
      # callback sidecar (e.g. `Caderneta & Caderneta::Validated`) over the
      # bare lexical class. Singleton methods aren't callback handlers, so
      # they keep the lexical resolution.
      unless @in_singleton_method
        refined = @current_method && @self_types_by_method[@current_method]
        return refined if refined && !refined.empty?
      end

      # Inside a module, an INSTANCE method's `self` is whatever includes it.
      # Unknowable from the nesting — claiming the module is a lie that reaches
      # the signature (`Token.authenticate(self, …)` typed its parameter
      # `ActionController::HttpAuthentication`, which has no `request`) — but
      # not unknowable in general: the self-type annotators answer it for a
      # covered concern, and that answer is the one the call site should see.
      # `Card::Entropy.for(self)` needs the `Card` half of `Card & Card::Entropic`
      # for `last_active_at`. Only for the module the file is named after, so a
      # sibling module in the same file cannot borrow it.
      # A `def self.x` in a module is different: there `self` IS the module.
      return module_self_type || "untyped" if !@in_singleton_method && @declaration_kinds.last == :module

      base = @class_name_stack.last || @caller_class_name
      return "untyped" unless base

      @in_singleton_method ? "singleton(#{base})" : base
    end

    # The answer for the module being visited. An unnameable one (a dynamic
    # constant path) falls back to the name the file stands for.
    def module_self_type
      @module_self_types[@module_name_stack.last || @caller_class_name]
    end

    # Resolves a `self.<method>` against the refined `self` type when the
    # enclosing method is covered by an after-validation callback (its `self`
    # is `Model & Model::Validated`). This makes `self.<association>` resolve
    # to the marker-decorated reader (e.g. `Caderneta & Caderneta::Validated`)
    # rather than the base nilable reader. Returns nil outside such methods,
    # so the normal `@method_return_types` path is preserved unchanged.
    def refined_self_method_type(method_name)
      return nil if @in_singleton_method
      return nil unless @method_type_resolver

      refined = @current_method && @self_types_by_method[@current_method]
      return nil if refined.nil? || refined.empty?

      resolved = @method_type_resolver.resolve(refined, method_name)
      resolved if resolved && resolved != "untyped"
    end

    # Resolver receiver.method() → tipo do retorno do method no receiver
    def resolve_method_chain(node)
      return nil unless @method_type_resolver

      # Constant receiver → singleton lookup (`Account.first`), not
      # instance. `self` in a class method's RBS is the class itself
      # (same convention as Analyzer#infer_attr_types_from_initialize).
      if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
        class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
        return nil unless class_name

        resolved = @method_type_resolver.resolve_class_method(class_name, node.name.to_s)
        return resolved == "self" ? class_name : resolved
      end

      receiver_type = resolve_receiver_type(node.receiver)
      return nil unless receiver_type && receiver_type != "untyped"

      resolved = @method_type_resolver.resolve(receiver_type, node.name.to_s)
      # `a&.b` with a nilable receiver: the nil flows into the result (on
      # a plain call the resolve is optimistic — `a.b` raises on nil).
      if resolved && node.safe_navigation? && receiver_type.end_with?("?")
        resolved = RbsInfer::Signatures::RbsParserUtil.nilablize(resolved)
      end
      resolved
    end

    # Resolver o tipo do receiver de um method call
    def resolve_receiver_type(node)
      case node
      when Prism::LocalVariableReadNode
        @local_var_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        lookup_ivar_type(node)
      when Prism::CallNode
        if node.receiver.nil?
          # Implicit `self.<method>` (ex: attr_reader/association). Inside a
          # callback-refined method, resolve against the refined self so a
          # `self.<association>` picks up the marker-decorated reader instead
          # of the base nilable one.
          refined_self_method_type(node.name.to_s) || @method_return_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        else
          resolve_method_chain(node)
        end
      when Prism::SelfNode
        # self → tipo da classe léxica (instância ou singleton); nil quando
        # desconhecido, mantendo a convenção nil-returning deste método.
        resolved = current_self_type
        resolved == "untyped" ? nil : resolved
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # Constant receiver → singleton method call on the class
        # (`Current.user = x`, `Notifier.notify(...)`). The class name is
        # itself the receiver's "type" for match_class? purposes
        # (felixefelip/rbs_infer#19).
        RbsInfer::Analyzer.extract_constant_path(node)
      end
    end

    # Extrair tipos de args de chamadas cross-class: receiver.method(arg1, arg2)
    def extract_cross_class_args(call_node, param_names)
      args = {}
      return args unless call_node.arguments

      # Args posicionais. Um `KeywordHashNode` normalmente é keyword — mas em Ruby 3,
      # quando o método NÃO aceita keywords, as keywords do call-site viram um Hash
      # POSICIONAL (`render partial: "x"` chega em `def render(target = nil, *rest)` como
      # `target = {partial: "x"}`). Reconhecemos isso quando nenhuma chave corresponde a um
      # parâmetro e ainda há slot posicional livre: sem isso o argumento desaparece, e o
      # parâmetro é tipado só pelos OUTROS call-sites — estreito demais, não apenas impreciso.
      index = 0
      call_node.arguments.arguments.each do |arg|
        break if index >= param_names.size

        if arg.is_a?(Prism::KeywordHashNode)
          next unless collapses_to_positional?(arg, param_names)

          args[param_names[index]] = hash_literal_type(arg)
          index += 1
          next
        end

        args[param_names[index]] = argument_type(arg)
        index += 1
      end

      # Args keyword
      call_node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        next if collapses_to_positional?(arg, param_names)

        arg.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          key = extract_symbol_key(elem.key)
          next unless key
          args[key] = argument_type(elem.value)
        end
      end

      args
    end

    # The checker's answer for an argument the structural resolver could not
    # type (felixefelip/rbs_infer#157).
    #
    # `self.author_name = value&.full_name` is a call site the collector matches
    # and then throws away: `value` is the enclosing method's parameter and the
    # send is safe-navigated, which the structural path does not follow. The
    # argument came out `untyped`, the Analyzer drops `untyped` usages, and the
    # attribute stayed untyped though Steep types that expression `String?`.
    #
    # Only a fallback: the structural answer wins when it has one, since it
    # carries the naming conventions (a class name for `Klass.new`, a record for
    # a hash literal) that a checker type does not.
    def argument_type(arg)
      resolved = resolve_value_type(arg)
      return resolved unless resolved.nil? || resolved == "untyped"

      expression_type(arg) || resolved
    end

    def expression_type(node)
      # Character column, like every other lookup into this map — Parser counts
      # characters where Prism also offers bytes (felixefelip/rbs_infer#142).
      type = @expression_types["#{node.location.start_line}:#{node.location.start_character_column}"]

      # `self` is a real RBS type, but it means "the receiver of THIS method" —
      # so carrying it into ANOTHER method's parameter says the argument is a
      # Token when it is a controller. The checker answers `self` for a `self`
      # node; here that answer is unusable.
      type unless type == "self"
    end

    # Whether a keyword hash at the call site is really a positional Hash: no key names a
    # parameter, so the callee cannot be receiving them as keywords.
    def collapses_to_positional?(node, param_names)
      keys = node.elements.filter_map { |e| e.is_a?(Prism::AssocNode) ? extract_symbol_key(e.key) : nil }
      return false if keys.empty?

      keys.none? { |k| param_names.include?(k) }
    end

    # A non-empty hash literal whose keys are ALL plain symbols — the only shape a record
    # type can describe. Anything else (string/dynamic keys, `**splat`) keeps the generic
    # inferrer's `Hash[K, V]`, which handles those.
    def record_shaped?(node)
      return false unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      return false if node.elements.empty?

      node.elements.all? { |e| e.is_a?(Prism::AssocNode) && extract_symbol_key(e.key) }
    end

    # `{ key: Type, ... }` for a literal keyword hash.
    def hash_literal_type(node)
      pairs = node.elements.filter_map do |e|
        next unless e.is_a?(Prism::AssocNode)
        key = extract_symbol_key(e.key) or next
        "#{key}: #{resolve_value_type(e.value) || "untyped"}"
      end

      return "Hash[Symbol, untyped]" if pairs.empty?

      "{ #{pairs.join(", ")} }"
    end
  end
end
