module RbsInfer::Inference
  # Resolve return types de métodos e tipos de instance variables
  # a partir de análise estática do corpo dos métodos.
  #
  # Extraído de Analyzer para manter responsabilidades separadas:
  # - improve_method_return_types: resolve return types de métodos via chain resolution
  # - infer_ivar_types: infere tipos de instance variables (@post, @posts, etc.)

  class ReturnTypeResolver
    include KnownReturnTypesBuilder

    # Split of ivar inference by receiver scope. `instance` maps ivar name →
    # type for plain instance variables (`@x: T`); `singleton` maps ivar name
    # → type for class-instance variables written inside `def self.x` /
    # `class << self` (`self.@x: T`) — felixefelip/rbs_infer#86.
    IvarInference = Struct.new(:instance, :singleton)

    def initialize(target_file:, target_class:, method_type_resolver:, constant_resolver:, instance_types: [], steep_bridge: nil)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @constant_resolver = constant_resolver
      @instance_types = instance_types
      @steep_bridge = steep_bridge
    end

    def improve_method_return_types(members, attr_types, parsed_target: nil)
      return unless parsed_target

      # Métodos com return type untyped — inclui `:method` (instance) e
      # `:class_method` (singleton, `def self.X`) porque o steep_bridge
      # devolve tipos pra ambos via `typing.each_typing` sem distinguir.
      untyped_methods = members.select { |m| method_member?(m) && m.signature =~ /->\ s*untyped$/ }
      return if untyped_methods.empty?

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)
      # A class method resolves against its OWN surface. The map above is
      # built from instance members, so applying it to a `:class_method`
      # would leak a homonymous instance method's return type onto it (and
      # the reverse, via the name-keyed Steep map below) —
      # felixefelip/rbs_infer#33.
      class_return_types = build_class_method_return_types(members, method_type_resolver: method_type_resolver, target_class: @target_class)

      # Aplicar tipos já resolvidos pelo resolver (ex: chamadas a métodos herdados)
      untyped_methods.each do |m|
        next if m.name == "initialize"
        # Setters' return is body/assignment-specific (`obj.x = v` evaluates
        # to the RHS, not the method's return) and is set by the owner-aware
        # TypeMerger passes from each def's body. `known_return_types` is
        # name-keyed, so resolving a setter here would leak a colliding
        # setter's return (e.g. a CurrentAttributes override onto the
        # generated module accessor) — felixefelip/rbs_infer#22.
        next if setter_name?(m.name)
        resolved = return_types_for(m, known_return_types, class_return_types)[m.name]
        if resolved && resolved != "untyped"
          m.signature = m.signature.sub(/-> untyped$/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(resolved)}")
        end
      end

      # Use Steep for any remaining untyped methods and to correct wrong block generic types
      if @steep_bridge && parsed_target.source
        still_untyped = members.select { |m| method_member?(m) && m.name != "initialize" && m.signature =~ /->\s*untyped$/ }
        # Kind-split so a `def self.x` reads Steep's singleton-method type,
        # not a homonymous `def x`'s (felixefelip/rbs_infer#33).
        steep_returns = @steep_bridge.method_return_types_by_kind(parsed_target.source)

        unless steep_returns[:instance].empty? && steep_returns[:singleton].empty?
          # Build def map for nil-return detection
          collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
          parsed_target.tree.accept(collector)
          def_map = {}
          collector.defs.each { |d| def_map[d.name.to_s] = d if d.is_a?(Prism::DefNode) }

          self_types = Set.new([@target_class] + @instance_types)

          still_untyped.each do |m|
            next if setter_name?(m.name)
            steep_type = steep_returns_for(m, steep_returns)[m.name]
            # `nil` is a genuine inference, not a fallback: the env is built with
            # `implicitly_returns_nil: false`, so Steep types a body as `nil` only
            # when it evaluates to nil. Emitting `-> nil` is precise and keeps a
            # genuinely nil-returning method (e.g. a `class_methods` def whose body
            # is `scope.find_each { … }`) from being stuck at `untyped`
            # (felixefelip/rbs_infer#60). `untyped`/`bot` stay filtered: the former
            # carries no information, the latter means an unreachable/error body.
            if steep_type && steep_type != "untyped" && steep_type != "bot"
              defn = def_map[m.name]

              # …but a `nil` from a *conditional* tail is not safe to emit: an
              # `if`/`unless`/`case` whose value branch is `untyped` makes Steep
              # collapse `untyped | nil` to `nil`, so `-> nil` would hide that
              # branch (e.g. `posts.destroy_all if cond`, where `destroy_all` is
              # `untyped`). Only take `nil` from an unconditional tail; otherwise
              # leave the method `untyped` (the honest answer).
              next if steep_type == "nil" && !unconditional_nil_tail?(defn)

              # Instance methods returning the same class (or host class for concerns) → self
              steep_type = "self" if self_return?(m, steep_type, self_types)

              # Check for early return nil in body
              if defn && has_nil_return?(defn)
                steep_type = RbsInfer::Signatures::RbsParserUtil.nilablize(steep_type)
              end

              m.signature = m.signature.sub(/-> untyped$/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(steep_type)}")
            end
          end

          # Correct already-typed methods where Steep detected BlockBodyTypeMismatch
          # (existing RBS had wrong type from previous generation)
          members.each do |m|
            next unless method_member?(m)
            next if m.name == "initialize"
            next if m.signature =~ /->\s*untyped$/
            steep_type = steep_returns_for(m, steep_returns)[m.name]
            next unless steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
            current_type = m.signature[/->\s*(.+)$/, 1]&.strip
            next if current_type == steep_type
            # Only override Array types (block generic correction)
            next unless current_type&.start_with?("Array[") && steep_type.start_with?("Array[")
            m.signature = m.signature.sub(/-> #{Regexp.escape(current_type)}$/, "-> #{steep_type}")
          end

          # Refine record types containing untyped values using Steep's body type inference
          members.each do |m|
            next unless method_member?(m)
            next if m.name == "initialize"
            current_type = m.signature[/->\s*(.+)$/, 1]&.strip
            next unless current_type&.start_with?("{") && current_type.include?("untyped")

            steep_type = steep_returns_for(m, steep_returns)[m.name]
            next unless steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
            next unless steep_type.start_with?("{")
            next if current_type == steep_type

            steep_type = "self" if self_return?(m, steep_type, self_types)

            defn = def_map[m.name]
            if defn && has_nil_return?(defn)
              steep_type = RbsInfer::Signatures::RbsParserUtil.nilablize(steep_type)
            end

            m.signature = m.signature.sub(/-> #{Regexp.escape(current_type)}$/, "-> #{steep_type}")
          end
        end
      end
    end

    def infer_ivar_types(members, attr_types, parsed_target: nil, method_param_types: {})
      return IvarInference.new({}, {}) unless parsed_target

      # Attr names already declared → the ivar they back is typed by the attr,
      # so we skip re-emitting it. Split by receiver scope: an instance attr
      # `x` covers the instance `@x`, but NOT the class-instance variable `@x`
      # written in `def self.x` (a distinct `self.@x` slot). Only a singleton
      # attr (`class << self; attr_accessor :x`) covers that one
      # (felixefelip/rbs_infer#86).
      attrs = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
      instance_attr_names = attrs.reject(&:singleton).map(&:name).to_set
      singleton_attr_names = attrs.select(&:singleton).map(&:name).to_set

      ivar_types = {}

      # Use Steep for ivar type resolution. Per felixefelip/rbs_infer#4,
      # the bridge returns union strings and applies the definite-init
      # rule itself (`@x: T1 | T2 | nil` when `@x` isn't written in
      # initialize). The fallback only fills ivars Steep didn't see.
      #
      # Exception: when Steep only saw `nil` writes (e.g. the nil kwarg
      # default assigned to the ivar, as in the expanded CurrentAttributes
      # `set`/`with` — rbs_infer#19), the "nil" carries no nominal type.
      # Don't close the door on the Prism fallback: the nil becomes mere
      # nilability and the fallback adds the call-sites' nominal types.
      steep_nil_only = Set.new
      if @steep_bridge && parsed_target.source
        steep_ivars = @steep_bridge.ivar_write_types(parsed_target.source, target_class: @target_class)
        steep_ivars.each do |name, type|
          next if instance_attr_names.include?(name)
          if type == "nil"
            steep_nil_only << name
            next
          end
          ivar_types[name] = type
        end
      end

      # Fallback: Prism-side ivar type inference for ivars Steep didn't
      # cover (e.g., parse failures or pure ivasgn that Steep can't type).
      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)

      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)

      initialized_ivars = collect_prism_initialized_ivars(parsed_target.tree)
      fallback_type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }
      # A `@x` written inside `def self.x` / `class << self` is a
      # class-instance variable, declared `self.@x` in RBS — a distinct slot
      # from the instance `@x`. Split the writes by the enclosing def's scope
      # (DefCollector already knows which defs are singleton).
      singleton_type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }

      collector.defs.each do |defn|
        param_types = method_param_types[defn.name.to_s] || {}
        singleton = collector.class_method?(defn)
        target = singleton ? singleton_type_sets : fallback_type_sets
        skip_names = singleton ? singleton_attr_names : instance_attr_names
        collect_ivar_writes(defn, known_return_types, target, skip_names, param_types: param_types)
      end

      # Class-instance variables are also written directly in the class body
      # (`@x = v` where `self` is the class) — the SAME `self.@x` slot as the
      # singleton-method writes above, and the only definite initialization one
      # can have (no constructor runs for them). Feeds both the type set and the
      # set of names that are non-nilable (felixefelip/rbs_infer#86).
      class_instance_initialized =
        collect_class_body_ivar_writes(parsed_target.tree, known_return_types, singleton_type_sets, singleton_attr_names)

      fallback_type_sets.each do |name, type_set|
        next if ivar_types.key?(name)
        force_nilable = !initialized_ivars.include?(name) || steep_nil_only.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        if emitted
          ivar_types[name] = emitted
          known_return_types[name] = emitted
        end
      end

      singleton_ivar_types = {}
      singleton_type_sets.each do |name, type_set|
        # No constructor initializes a class-instance variable, so the
        # definite-init rule keys off a class-body write (where `self` is the
        # class) rather than `initialize` — nilable everywhere else.
        force_nilable = !class_instance_initialized.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        singleton_ivar_types[name] = emitted if emitted
      end

      IvarInference.new(ivar_types, singleton_ivar_types)
    end

    # Returns Set[String] of ivar names (without `@`) definitely initialized in
    # the TARGET class: assigned in its `def initialize`, directly in its class
    # body, OR in a method that `initialize` invokes on `self` (transitively).
    # Public so the analyzer can apply the definite-initialization rule to attr
    # types (felixefelip/rbs_infer#71).
    #
    # Transitive reach: `@x` set in `atribui_user` counts as initialized when
    # `initialize` calls `atribui_user` — a human reads such an ivar as non-nil
    # (the constructor always runs it), so `TagDestroy#user` (set in
    # `atribui_user`, called from `initialize`) stays non-nil instead of being
    # wrongly nilablized. Follows the same optimistic style as the direct rule
    # (a write reachable from `initialize` counts, without a strict
    # unconditional-flow analysis).
    #
    # Scoped to `@target_class`: walking the whole file let a sibling class's
    # `initialize` leak in — e.g. `Example3::User#initialize`'s `@name = name`
    # made `Example3::Foo`'s never-initialized `name` look initialized, so the
    # definite-init `?` was wrongly skipped (the cross-class pooling of
    # felixefelip/rbs_infer#38, #69).
    def collect_prism_initialized_ivars(tree)
      result = Set.new
      method_defs = {}
      bodies = []
      each_target_class_body(tree, class_path: []) do |body|
        bodies << body
        collect_instance_method_defs(body, method_defs)
      end
      bodies.each do |body|
        walk_prism_init_targets(body, in_init: false, in_class_body: true, result: result)
      end
      # Transitive: ivars written by methods reachable from `initialize` via
      # self-calls (`atribui_user` → `@user = ...`).
      (method_defs["initialize"] || []).each do |init_def|
        next unless init_def.body
        collect_transitive_init_ivars(init_def.body, method_defs, result, visited: Set.new(["initialize"]))
      end
      result
    end

    # Indexes every instance method (`def foo`, receiver-less) of a class body
    # into `acc` (`name => [DefNode, ...]`), stopping at nested class/module
    # boundaries and not descending into method bodies. Reopens across bodies
    # accumulate into the same map (felixefelip/rbs_infer#71).
    def collect_instance_method_defs(node, acc)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::DefNode
        (acc[node.name.to_s] ||= []) << node if node.receiver.nil?
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        # different scope — not this class's instance methods
      else
        node.compact_child_nodes.each { |c| collect_instance_method_defs(c, acc) }
      end
    end

    # For every `self`-receiver (or implicit-self) call in `body`, if it names a
    # method of the target class, folds that method's ivar writes into `result`
    # and recurses through its own self-calls. `visited` guards against
    # recursion cycles (felixefelip/rbs_infer#71).
    def collect_transitive_init_ivars(body, method_defs, result, visited:)
      call_names = Set.new
      collect_self_call_names(body, call_names)
      call_names.each do |name|
        next if visited.include?(name)

        visited << name
        (method_defs[name] || []).each do |d|
          next unless d.body

          walk_prism_init_targets(d.body, in_init: true, in_class_body: false, result: result)
          collect_transitive_init_ivars(d.body, method_defs, result, visited: visited)
        end
      end
    end

    # Collects the names of every non-setter call on `self` (explicit or
    # implicit receiver) within `node`, without descending into nested method
    # definitions (their calls belong to a different flow).
    def collect_self_call_names(node, acc)
      return unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode) &&
         (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
         !node.name.to_s.end_with?("=")
        acc << node.name.to_s
      end

      node.compact_child_nodes.each do |c|
        collect_self_call_names(c, acc) unless c.is_a?(Prism::DefNode)
      end
    end

    private

    # Collects class-instance variables written directly in the target class's
    # body (`@x = v` where `self` is the class). Adds each write's type to
    # `type_sets` and returns the Set of names so written — the only definite
    # initialization a class-instance variable can have, since no constructor
    # runs for it (felixefelip/rbs_infer#86).
    #
    # Scoped to `@target_class`: a sibling class in the same file must not
    # contribute here (the cross-class pooling of felixefelip/rbs_infer#38).
    def collect_class_body_ivar_writes(tree, known_return_types, type_sets, attr_names)
      result = Set.new
      each_target_class_body(tree, class_path: []) do |body|
        collect_body_level_ivar_writes(body, known_return_types, type_sets, attr_names, result)
      end
      result
    end

    # Yields the body node of every `class`/`module` in the file whose fully
    # qualified path equals `@target_class` (reopens included).
    def each_target_class_body(node, class_path:, &blk)
      return unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        inner = class_path + [RbsInfer::Analyzer.extract_constant_path(node.constant_path)]
        blk.call(node.body) if node.body && inner.join("::") == @target_class
        each_target_class_body(node.body, class_path: inner, &blk) if node.body
      else
        node.compact_child_nodes.each { |c| each_target_class_body(c, class_path: class_path, &blk) }
      end
    end

    # Walks a class body's statements collecting ivar writes at body level.
    # Stops at any `def`/`class << self`/nested class/module: writes past those
    # boundaries are a method's instance ivars, a singleton class's own ivars,
    # or another class's — none of them THIS class's class-instance variables.
    def collect_body_level_ivar_writes(node, known_return_types, type_sets, attr_names, result)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::DefNode, Prism::SingletonClassNode, Prism::ClassNode, Prism::ModuleNode
        # boundary — do not descend
      when Prism::InstanceVariableWriteNode,
           Prism::InstanceVariableOrWriteNode,
           Prism::InstanceVariableAndWriteNode
        name = node.name.to_s.sub(/\A@/, "")
        unless attr_names.include?(name)
          inferred = basic_value_type(node.value, known_return_types)
          type_sets[name].add(inferred) if inferred
          result << name
        end
        node.compact_child_nodes.each { |c| collect_body_level_ivar_writes(c, known_return_types, type_sets, attr_names, result) }
      else
        node.compact_child_nodes.each { |c| collect_body_level_ivar_writes(c, known_return_types, type_sets, attr_names, result) }
      end
    end

    attr_reader :method_type_resolver

    # `user=`-style writer (not `==`/`<=`/`[]=` operators).
    def setter_name?(name)
      name.to_s.match?(/[A-Za-z0-9_]=\z/) && !name.to_s.start_with?("[")
    end

    # Singleton (`def self.X`) é coletado como `:class_method` em
    # `class_member_collector.rb` mas tem o mesmo tratamento de inferência de
    # retorno que `:method` (steep_bridge devolve por nome para ambos).
    def method_member?(member)
      member.kind == :method || member.kind == :class_method
    end

    # Pick the return-type map matching a member's kind so instance and
    # class methods never read each other's types (felixefelip/rbs_infer#33).
    def return_types_for(member, instance_map, class_map)
      member.kind == :class_method ? class_map : instance_map
    end

    # Same selection for the kind-split Steep map (`{instance:, singleton:}`).
    def steep_returns_for(member, steep_returns)
      member.kind == :class_method ? steep_returns[:singleton] : steep_returns[:instance]
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
      member.kind != :class_method && self_types.include?(steep_type)
    end

    # Verifica se o corpo do método contém `return nil` ou `return` (implícito nil)
    def has_nil_return?(defn)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
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
      body = defn&.body
      return false unless body.is_a?(Prism::StatementsNode)

      tail = body.body.last
      return false if tail.nil?

      CONDITIONAL_TAIL_NODES.none? { |klass| tail.is_a?(klass) }
    end

    def collect_ivar_writes(node, known_return_types, type_sets, attr_names, param_types: {})
      queue = [node]
      while (current = queue.shift)
        # `@x = v`, plus `@x ||= v` / `@x &&= v` — all carry `.name`/`.value`
        # and assign approximately the RHS type. `||=`/`&&=` were dropped
        # before (felixefelip/rbs_infer#85); `InstanceVariableOperatorWriteNode`
        # (`+=`, `<<=`) stays out — its result type is the operator's, not
        # `.value`'s.
        if current.is_a?(Prism::InstanceVariableWriteNode) ||
           current.is_a?(Prism::InstanceVariableOrWriteNode) ||
           current.is_a?(Prism::InstanceVariableAndWriteNode)
          name = current.name.to_s.sub(/\A@/, "")
          unless attr_names.include?(name)
            inferred = basic_value_type(current.value, known_return_types)
            # `@x = param` where the param's type came from cross-class
            # call-sites (e.g. setter `def x=(value); @x = value; end`
            # typed by `Obj.x = expr` in other files) —
            # felixefelip/rbs_infer#19.
            if inferred.nil? && current.value.is_a?(Prism::LocalVariableReadNode)
              inferred = param_types[current.value.name.to_s]
            end
            type_sets[name].add(inferred) if inferred
          end
        end
        queue.concat(current.compact_child_nodes)
      end
    end

    # Walks the Prism tree of a class body and collects ivar names that
    # Walks Prism nodes collecting ivar names assigned inside `initialize`
    # or a class body (outside any method). Mirrors
    # `SteepBridge#collect_initialized_ivars` for the Prism path. Used by
    # the definite-initialization rule (felixefelip/rbs_infer#4).
    def walk_prism_init_targets(node, in_init:, in_class_body:, result:)
      return unless node

      case node
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        body = node.body
        walk_prism_init_targets(body, in_init: false, in_class_body: true, result: result) if body
      when Prism::DefNode
        if node.name == :initialize && node.receiver.nil?
          walk_prism_init_targets(node.body, in_init: true, in_class_body: false, result: result) if node.body
        end
        # other defs: do not descend (their ivasgns don't count as init)
      when Prism::InstanceVariableWriteNode
        if in_init || in_class_body
          result << node.name.to_s.sub(/\A@/, "")
        end
        walk_prism_init_targets(node.value, in_init: in_init, in_class_body: in_class_body, result: result) if node.value
      when Prism::CallNode
        # `self.x = expr` inside initialize or class body counts as init
        # for `@x` if `x=` is a writer/accessor on this class. We mark
        # optimistically; non-attr `x=` methods would harmlessly mark a
        # name that never appears in the type-set (so emits nothing).
        if (in_init || in_class_body) &&
           node.name.to_s.end_with?("=") && node.name != :"==" &&
           (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          ivar_name = node.name.to_s.chomp("=").sub(/\A@/, "")
          result << ivar_name unless ivar_name.empty?
        end
        node.compact_child_nodes.each do |c|
          walk_prism_init_targets(c, in_init: in_init, in_class_body: in_class_body, result: result)
        end
      else
        node.compact_child_nodes.each do |c|
          walk_prism_init_targets(c, in_init: in_init, in_class_body: in_class_body, result: result)
        end
      end
    end

    # Basic type inference for ivar assignment values — handles literals,
    # Klass.new, and simple same-class method lookups.
    # Complex chain resolution is delegated to Steep.
    def basic_value_type(node, known_return_types)
      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, known_types: known_return_types, context_class: @target_class, constant_resolver: @constant_resolver)
      return literal if literal

      case node
      when Prism::SelfNode then @target_class
      when Prism::CallNode
        if node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        elsif node.receiver.nil?
          known_return_types[node.name.to_s]
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # Constant's VALUE type, not its bare name (#56).
        RbsInfer::AST::NodeTypeInferrer.resolve_constant_value_type(node, namespace: @target_class, constant_resolver: @constant_resolver)
      end
    end
  end
end
