# frozen_string_literal: true

module RbsInfer::Inference
  # Infere tipos de instance variables (@post, @posts, etc.) a partir das
  # escritas no corpo da classe e dos métodos.
  class IvarTypeInferrer
    include KnownReturnTypesBuilder

    # Split of ivar inference by receiver scope. `instance` maps ivar name →
    # type for plain instance variables (`@x: T`); `singleton` maps ivar name
    # → type for class-instance variables written inside `def self.x` /
    # `class << self` (`self.@x: T`) — felixefelip/rbs_infer#86.
    #
    # `by_module` is the same instance split one level down: `owner name →
    # { ivar name → type }` for the ivars a NESTED module writes, which are the
    # module's and not the class's. The builder emits them inside that module's
    # own block, where the method that writes them will look for them
    # (felixefelip/rbs_infer#249).
    IvarInference = Struct.new(:instance, :singleton, :by_module)

    def initialize(target_class:, method_type_resolver:, constant_resolver:, instance_types:, steep_bridge:)
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @constant_resolver = constant_resolver
      @instance_types = instance_types
      @steep_bridge = steep_bridge
    end

    # The type each method writes to each ivar of the class, by method name.
    def writes_per_method(parsed_target)
      return {} unless @steep_bridge && parsed_target&.source

      @steep_bridge.ivar_write_types_per_method(parsed_target.source, target_class: @target_class)
    end

    def infer_ivar_types(members, attr_types, parsed_target: nil, method_param_types: {}) # rubocop:todo Metrics/MethodLength
      return IvarInference.new({}, {}, {}) unless parsed_target

      # Attr names already declared → the ivar they back is typed by the attr,
      # so we skip re-emitting it. Split by receiver scope: an instance attr
      # `x` covers the instance `@x`, but NOT the class-instance variable `@x`
      # written in `def self.x` (a distinct `self.@x` slot). Only a singleton
      # attr (`class << self; attr_accessor :x`) covers that one
      # (felixefelip/rbs_infer#86).
      attrs = members.select { |m| %i[attr_accessor attr_reader attr_writer].include?(m.kind) }
      # Every non-singleton attr, wherever it is declared: one in a nested module
      # the class includes still types the class's `@x`, so it still means "don't
      # re-emit". The owner matters for WHERE a slot is declared, not for whether
      # an accessor already covers it.
      instance_attr_names = attrs.reject(&:singleton).map(&:name).to_set
      singleton_attr_names = attrs.select(&:singleton).map(&:name).to_set
      # The same coverage question asked of one module: its own attrs cover its
      # own ivars, and a sibling module's do not.
      module_attr_names = Hash.new { |h, k| h[k] = Set.new }
      attrs.reject(&:singleton).select(&:owner).each { |a| module_attr_names[a.owner] << a.name }

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
      module_ivar_types = Hash.new { |h, k| h[k] = {} }
      # The `self.@x` slot, answered by the same machinery as the instance one.
      # It used to have only the Prism fallback below, which reads literals and
      # little else — so `@block = block` in a `def self.store` produced no
      # declaration at all, and the proc the slot holds lost the `[self:]`
      # binding it carries (felixefelip/rbs_infer#252).
      steep_singleton_ivars = {}
      if @steep_bridge && parsed_target.source
        steep_singleton_ivars = @steep_bridge.ivar_write_types(parsed_target.source, target_class: @target_class,
                                                                                     singleton: true)
        steep_ivars = @steep_bridge.ivar_write_types(parsed_target.source, target_class: @target_class,
                                                                           singleton: false)
        steep_ivars.each do |name, type|
          next if instance_attr_names.include?(name)

          if type == "nil"
            steep_nil_only << name
            next
          end
          ivar_types[name] = type
        end

        # Each nested module is its own scope for this question, so it is asked
        # as one — `ivar_write_types` already takes the scope to answer for, and
        # since felixefelip/rbs_infer#249 it answers for that scope EXACTLY
        # rather than sweeping nested modules into their enclosing class.
        members.filter_map(&:owner).uniq.each do |owner|
          @steep_bridge.ivar_write_types(parsed_target.source, target_class: "#{@target_class}::#{owner}",
                                                               singleton: false)
                       .each do |name, type|
            next if module_attr_names[owner].include?(name) || type == "nil"

            module_ivar_types[owner][name] = type
          end
        end
      end

      # Fallback: Prism-side ivar type inference for ivars Steep didn't
      # cover (e.g., parse failures or pure ivasgn that Steep can't type).
      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver,
                                                                         target_class: @target_class, instance_types: @instance_types)

      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)

      initialized_ivars = collect_prism_initialized_ivars(parsed_target.tree)
      fallback_type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }
      # A `@x` written inside `def self.x` / `class << self` is a
      # class-instance variable, declared `self.@x` in RBS — a distinct slot
      # from the instance `@x`. Split the writes by the enclosing def's scope
      # (DefCollector already knows which defs are singleton).
      singleton_type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }

      # The fallback's half of the owner split. A nested module's instance
      # methods write the MODULE's ivars, so they get their own bucket rather
      # than pooling into the class's — the same division the Steep pass above
      # makes by asking per scope (felixefelip/rbs_infer#249).
      module_type_sets = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = IvarTypeSet.new } }

      collector.defs.each do |defn|
        singleton = collector.class_method?(defn)
        owner = collector.owner_of(defn)
        # Keyed by the method's identity, not its name — see MethodKey
        # (felixefelip/rbs_infer#215).
        param_types = RbsInfer::Inference::MethodKey.lookup(
          method_param_types,
          defn.name.to_s,
          owner: RbsInfer::Inference::MethodKey.qualify_owner(@target_class, owner),
          kind: singleton ? :class_method : :method
        ) || {}
        target = if singleton
                   singleton_type_sets
                 elsif owner
                   module_type_sets[owner]
                 else
                   fallback_type_sets
                 end
        skip_names = if singleton
                       singleton_attr_names
                     elsif owner
                       module_attr_names[owner]
                     else
                       instance_attr_names
                     end
        collect_ivar_writes(defn, known_return_types, target, skip_names, param_types: param_types)
      end

      # Class-instance variables are also written directly in the class body
      # (`@x = v` where `self` is the class) — the SAME `self.@x` slot as the
      # singleton-method writes above, and the only definite initialization one
      # can have (no constructor runs for them). Feeds both the type set and the
      # set of names that are non-nilable (felixefelip/rbs_infer#86).
      class_instance_initialized =
        collect_class_body_ivar_writes(parsed_target.tree, known_return_types, singleton_type_sets,
                                       singleton_attr_names)

      fallback_type_sets.each do |name, type_set|
        next if ivar_types.key?(name)

        force_nilable = !initialized_ivars.include?(name) || steep_nil_only.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        if emitted
          ivar_types[name] = emitted
          known_return_types[name] = emitted
        end
      end

      # Steep first, exactly as the instance slot does it: the fallback only
      # fills what the checker did not see.
      singleton_ivar_types = steep_singleton_ivars.reject { |name, _| singleton_attr_names.include?(name) }
      singleton_type_sets.each do |name, type_set|
        next if singleton_ivar_types.key?(name)

        # No constructor initializes a class-instance variable, so the
        # definite-init rule keys off a class-body write (where `self` is the
        # class) rather than `initialize` — nilable everywhere else.
        force_nilable = !class_instance_initialized.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        singleton_ivar_types[name] = emitted if emitted
      end

      # A module has no constructor of its own — whoever includes or extends it
      # runs the write, and nothing here can say it ran. So every ivar a nested
      # module writes is nilable, which is the same conclusion the class-level
      # rule reaches for an ivar that `initialize` never touches.
      module_type_sets.each do |owner, type_sets|
        type_sets.each do |name, type_set|
          next if module_ivar_types[owner].key?(name)

          emitted = type_set.emit(force_nilable: true)
          module_ivar_types[owner][name] = emitted if emitted
        end
      end

      IvarInference.new(ivar_types, singleton_ivar_types, module_ivar_types.reject { |_, ivars| ivars.empty? })
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

    attr_reader :method_type_resolver

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
    # rubocop:todo-next Metrics/MethodLength
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
        node.compact_child_nodes.each do |c|
          collect_body_level_ivar_writes(c, known_return_types, type_sets, attr_names, result)
        end
      when Prism::MultiWriteNode
        RbsInfer::AST::MultiWriteDecomposer.ivar_name_pairs(node).each do |name, value|
          next if attr_names.include?(name)

          inferred = basic_value_type(value, known_return_types)
          type_sets[name].add(inferred) if inferred
          result << name
        end
        node.compact_child_nodes.each do |c|
          collect_body_level_ivar_writes(c, known_return_types, type_sets, attr_names, result)
        end
      else
        node.compact_child_nodes.each do |c|
          collect_body_level_ivar_writes(c, known_return_types, type_sets, attr_names, result)
        end
      end
    end

    # rubocop:todo-next Metrics/MethodLength
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

        # `@a, @b = x, y` — same contribution as the one-per-line form
        # (felixefelip/rbs_infer#183).
        RbsInfer::AST::MultiWriteDecomposer.ivar_name_pairs(current).each do |name, value|
          next if attr_names.include?(name)

          inferred = basic_value_type(value, known_return_types)
          inferred = param_types[value.name.to_s] if inferred.nil? && value.is_a?(Prism::LocalVariableReadNode)
          type_sets[name].add(inferred) if inferred
        end

        queue.concat(current.compact_child_nodes)
      end
    end

    # Walks the Prism tree of a class body and collects ivar names that
    # Walks Prism nodes collecting ivar names assigned inside `initialize`
    # or a class body (outside any method). Mirrors
    # `SteepBridge#collect_initialized_ivars` for the Prism path. Used by
    # the definite-initialization rule (felixefelip/rbs_infer#4).
    def walk_prism_init_targets(node, in_init:, in_class_body:, result:) # rubocop:todo Metrics/MethodLength
      return unless node

      case node
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        body = node.body
        walk_prism_init_targets(body, in_init: false, in_class_body: true, result: result) if body
      when Prism::DefNode
        if node.name == :initialize && node.receiver.nil? && node.body
          walk_prism_init_targets(node.body, in_init: true, in_class_body: false, result: result)
        end
        # other defs: do not descend (their ivasgns don't count as init)
      when Prism::InstanceVariableWriteNode
        if in_init || in_class_body
          result << node.name.to_s.sub(/\A@/, "")
        end
        if node.value
          walk_prism_init_targets(node.value, in_init: in_init, in_class_body: in_class_body,
                                              result: result)
        end
      when Prism::MultiWriteNode
        # `@a, @b = x, y` initializes both, whatever the values look like — so
        # this uses every ivar target, not just the pairable ones.
        if in_init || in_class_body
          result.merge(RbsInfer::AST::MultiWriteDecomposer.ivar_target_names(node))
        end
        if node.value
          walk_prism_init_targets(node.value, in_init: in_init, in_class_body: in_class_body,
                                              result: result)
        end
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
      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, known_types: known_return_types,
                                                                              context_class: @target_class, constant_resolver: @constant_resolver)
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
        RbsInfer::AST::NodeTypeInferrer.resolve_constant_value_type(node, namespace: @target_class,
                                                                          constant_resolver: @constant_resolver)
      end
    end
  end
end
