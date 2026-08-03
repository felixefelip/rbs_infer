class RbsInfer::Signatures::SteepBridge
  class IvarWriteAnalyzer
    def initialize(steep_bridge:)
      @steep_bridge = steep_bridge
    end

    # Returns { "var_name" => "Type" } for instance variable writes
    # observed in the source, scoped to `target_class`. The var name is
    # without the leading `@`.
    #
    # `target_class` matters when a single file defines several classes
    # (initializers, `lib/*_ext.rb`, fixtures): only writes lexically
    # inside `target_class` (or a module nested-and-included under it,
    # e.g. an expander's `GeneratedAttributeMethods`) count, so a sibling
    # class's `@x` never bleeds in (felixefelip/rbs_infer#38). Pass `nil`
    # to opt out of scoping (whole-file behavior).
    #
    # Writes counted:
    #
    # - Direct `:ivasgn` (`@x = expr`) anywhere in any method.
    # - `:send` of `x=` with receiver `nil` (implicit self) or `:self`,
    #   when `x=` is declared as `attr_writer :x` / `attr_accessor :x`
    #   on the same class. The argument's type contributes to the union
    #   of `@x` (felixefelip/rbs_infer#4 + steep#18 mapping).
    #
    # When no write is observed inside `def initialize` (nor at class-body
    # scope) of `target_class`, the emitted type gets `| nil`
    # (definite-initialization rule). The narrowing is then reabsorbed by
    # steep#16 within methods that explicitly assign before reading.
    def ivar_write_types(source_code, target_class:)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      type_sets = Hash.new { |h, k| h[k] = RbsInfer::Inference::IvarTypeSet.new }
      initialized = collect_initialized_ivars(source_node, target_class: target_class)
      attr_writer_to_ivar = collect_attr_writers(source_node)
      # Only writes lexically inside `target_class` count. A single file can
      # define several classes (initializers, `lib/*_ext.rb`, the dummy-app
      # fixtures), and without scoping their ivars — and same-named methods
      # like `initialize` — pool into each other (felixefelip/rbs_infer#38).
      # `each_typing` enumerates the whole file, so we filter it by node
      # identity against the set of writes that belong to `target_class`.
      in_scope = collect_scoped_write_node_ids(source_node, attr_writer_to_ivar, target_class)

      typing.each_typing do |node, type|
        next unless in_scope.include?(node.object_id)

        case node.type
        when :ivasgn, :or_asgn, :and_asgn
          parts = ivar_write_name_and_rhs(node)
          next unless parts

          var_name, rhs = parts
          rhs_type = intrinsic_type_of(rhs, typing)
          next unless rhs_type

          type_sets[var_name].add(format_type(rhs_type))
        when :send
          receiver, method_name, *args = node.children
          next unless attr_writer_to_ivar.key?(method_name)
          next unless receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)
          next if args.empty?

          arg = args[0]
          arg_type = intrinsic_type_of(arg, typing)
          next unless arg_type

          ivar = attr_writer_to_ivar.fetch(method_name)
          type_sets[ivar].add(format_type(arg_type))
        end
      end

      result = {}
      type_sets.each do |name, type_set|
        force_nilable = !initialized.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        result[name] = emitted if emitted
      end
      result
    end

    # Returns `{ "method_name" => { "ivar_name" => "type" } }` for every
    # method of `target_class` that writes (directly or via attr_writer)
    # an instance variable. The per-method shape is what enables consumers
    # (e.g., the ERB convention generator) to narrow an ivar's type to
    # the contribution of a specific writer — rather than always seeing
    # the wide union of all observed writes.
    #
    # Scoped to `target_class` so that same-named methods across classes
    # in one file (`Foo#initialize` and `Bar#initialize`) don't pool into
    # a single `"initialize"` bucket (felixefelip/rbs_infer#38). Pass
    # `nil` to opt out of scoping.
    #
    # Coverage mirrors `ivar_write_types`:
    # - Direct `:ivasgn` (`@x = expr`) inside any method.
    # - `:send` matching `attr_writer :x` / `attr_accessor :x` declared
    #   on the same class, with implicit-self or `self` receiver.
    #
    # Top-level `:ivasgn` outside any method (class-instance variable in
    # class body) is intentionally NOT recorded here — there's no method
    # to attribute it to. Use `collect_initialized_ivars` for that case.
    def ivar_write_types_per_method(source_code, target_class:)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      attr_writer_to_ivar = collect_attr_writers(source_node)
      per_method_sets = Hash.new do |h, k|
        h[k] = Hash.new { |h2, k2| h2[k2] = RbsInfer::Inference::IvarTypeSet.new }
      end

      collect_ivar_writes_per_method(
        source_node,
        typing: typing,
        attr_writer_to_ivar: attr_writer_to_ivar,
        current_method: nil,
        namespace: [],
        target_class: target_class,
        result: per_method_sets
      )

      result = {}
      per_method_sets.each do |method_name, ivar_sets|
        ivar_types = {}
        ivar_sets.each do |ivar_name, type_set|
          # `force_nilable: false` — this method already filters per
          # writer; nilability decisions live at the consumer
          # (controller declaration uses `ivar_write_types`, the
          # view consumer wants the writer's raw contribution).
          emitted = type_set.emit(force_nilable: false)
          ivar_types[ivar_name] = emitted if emitted
        end
        result[method_name] = ivar_types unless ivar_types.empty?
      end
      result
    end

    private

    # Returns Set[String] of ivar names (without leading `@`) that are
    # assigned inside `def initialize` of `target_class`, or at its
    # class-body scope. Used by the definite-initialization rule to
    # decide whether `nil` is added to the union — so it must be scoped to
    # the same class the writes are, or an `@x` initialized in a *sibling*
    # class in the same file would wrongly suppress the `| nil` here.
    def collect_initialized_ivars(node, target_class:)
      result = Set.new
      walk_ivar_init_targets(node, in_init: false, in_class_body: false,
                                   namespace: [], target_class: target_class, result: result)
      result
    end

    # Walks `node` looking for `:ivasgn` targets that count as definite
    # initialization (inside `def initialize` or directly in a class body
    # outside any method). Does not descend into non-initialize defs.
    def walk_ivar_init_targets(node, in_init:, in_class_body:, namespace:, target_class:, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        body = node.type == :class ? node.children[2] : node.children[1]
        walk_ivar_init_targets(body, in_init: false, in_class_body: true,
                                     namespace: push_namespace(namespace, node),
                                     target_class: target_class, result: result) if body
      when :sclass
        body = node.children[1]
        walk_ivar_init_targets(body, in_init: false, in_class_body: true,
                                     namespace: namespace, target_class: target_class, result: result) if body
      when :def
        if node.children[0] == :initialize
          body = node.children[2]
          walk_ivar_init_targets(body, in_init: true, in_class_body: false,
                                       namespace: namespace, target_class: target_class, result: result) if body
        end
      when :defs
        # def self.X — singleton method, skip; ivar there is class-instance
        # variable, not relevant for instance ivar initialization.
      when :ivasgn
        if (in_init || in_class_body) && class_scope_match?(namespace, target_class)
          var_name = node.children[0].to_s.sub(/\A@/, "")
          result << var_name
        end
        # also walk RHS for nested classes (`@x = Class.new { @y = ... }` is
        # exotic but harmless to descend)
        rhs = node.children[1]
        walk_ivar_init_targets(rhs, in_init: in_init, in_class_body: in_class_body,
                                    namespace: namespace, target_class: target_class, result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if (in_init || in_class_body) && class_scope_match?(namespace, target_class) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           method_name.to_s.end_with?("=") &&
           method_name != :==
          # `self.x = expr` inside initialize or class body — counts as
          # init if `x=` is an attr_writer/accessor on this class. Resolve
          # lazily via the same attr-writer walk so we don't need to
          # double-pass.
          # Note: we ALWAYS mark `x` as initialized here when the shape
          # matches; the attr_writer registry filter happens at the
          # ivar-collection step. Acceptable false-positive: a custom
          # `x=` method in initialize won't actually init `@x`, but we'd
          # still mark it — the type set will be empty for that name and
          # nothing is emitted. So no observable bug.
          ivar = method_name.to_s.chomp("=").sub(/\A@/, "")
          result << ivar unless ivar.empty?
        end
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                    namespace: namespace, target_class: target_class, result: result)
        end
      when :begin
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                    namespace: namespace, target_class: target_class, result: result)
        end
      else
        # Descend through everything else (if/case/blocks/etc.) while
        # keeping the current scope flags.
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                    namespace: namespace, target_class: target_class, result: result)
        end
      end
    end

    # Walks `node` collecting `attr_writer :x` / `attr_accessor :x` /
    # `attr_reader :x` declarations in class bodies; only writer/accessor
    # contribute to the `{ :x= => "x" }` map. Reader entries are skipped
    # because they don't define `x=`.
    def walk_attr_writer_decls(node, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        body = node.type == :class ? node.children[2] : node.children[1]
        if body
          # Only direct children of the class body count — `attr_writer`
          # inside a method body doesn't define accessors on the class.
          decls = body.type == :begin ? body.children : [body]
          decls.each do |child|
            next unless child.is_a?(::Parser::AST::Node)
            next unless child.type == :send
            next unless child.children[0].nil? # implicit-self receiver
            next unless %i[attr_writer attr_accessor].include?(child.children[1])

            child.children[2..].each do |arg|
              next unless arg.is_a?(::Parser::AST::Node)
              next unless arg.type == :sym

              name = arg.children[0].to_s
              result[:"#{name}="] = name
            end
          end
          # Descend into nested classes.
          decls.each { |c| walk_attr_writer_decls(c, result: result) }
        end
      when :sclass
        body = node.children[1]
        walk_attr_writer_decls(body, result: result) if body
      else
        node.children.each { |c| walk_attr_writer_decls(c, result: result) }
      end
    end

    # Returns { :method_name= => "ivar_name_without_@" } for every
    # `attr_writer :x` / `attr_accessor :x` declared in the source.
    # Used to map `self.x = expr` call sites to the underlying `@x`.
    def collect_attr_writers(node)
      result = {}
      walk_attr_writer_decls(node, result: result)
      result
    end

    # Object-ids of the `:ivasgn` / attr-writer `:send` nodes that live
    # lexically inside `target_class`. `ivar_write_types` filters the
    # whole-file `each_typing` stream against this set so a sibling class
    # in the same file can't contribute to the target's ivar types. Using
    # object-ids (not the nodes) sidesteps `Parser::AST::Node`'s
    # structural `==`, which would conflate two identical writes in
    # different classes.
    def collect_scoped_write_node_ids(node, attr_writer_to_ivar, target_class, namespace: [], in_def: false,
                                      result: Set.new)
      return result unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        body = node.type == :class ? node.children[2] : node.children[1]
        collect_scoped_write_node_ids(body, attr_writer_to_ivar, target_class,
                                      namespace: push_namespace(namespace, node),
                                      in_def: false, result: result) if body
      when :sclass, :defs
        # Singleton scope (`class << self` / `def self.x`): `self` is the class,
        # so every `@x = ...` inside is a class-instance variable (`self.@x`),
        # never an instance ivar. Don't descend — these writes must not land in
        # the instance-ivar map (felixefelip/rbs_infer#86). The Prism path in
        # ReturnTypeResolver collects them separately.
      when :def
        body = node.children[2]
        collect_scoped_write_node_ids(body, attr_writer_to_ivar, target_class,
                                      namespace: namespace, in_def: true, result: result) if body
      when :ivasgn
        # Only writes inside an instance method are instance ivars. A bare
        # `@x = v` in the class body (`in_def` false) is a class-instance
        # variable — `self` is the class there too (felixefelip/rbs_infer#86).
        result << node.object_id if in_def && class_scope_match?(namespace, target_class)
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, in_def: in_def,
                                                                              result: result)
        end
      when :or_asgn, :and_asgn
        # `@x ||= v` / `@x &&= v`: the write `each_typing` will key on is this
        # whole node, not its argument-less inner `:ivasgn`, so collect this
        # id (felixefelip/rbs_infer#85).
        if in_def && node.children[0].type == :ivasgn && class_scope_match?(namespace, target_class)
          result << node.object_id
        end
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, in_def: in_def,
                                                                              result: result)
        end
      when :send
        receiver, method_name = node.children[0], node.children[1]
        if in_def && attr_writer_to_ivar.key?(method_name) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           class_scope_match?(namespace, target_class)
          result << node.object_id
        end
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, in_def: in_def,
                                                                              result: result)
        end
      else
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, in_def: in_def,
                                                                              result: result)
        end
      end

      result
    end

    # Walks `node` accumulating ivar writes attributed to the enclosing
    # `def`. Propagates `current_method` through descent; only records
    # writes that happen inside a `:def` (writes in class body are
    # ignored here since they don't belong to any callable). Mirrors the
    # filter logic of `ivar_write_types` for both `:ivasgn` and
    # attr_writer-style `:send`.
    def collect_ivar_writes_per_method(node, typing:, attr_writer_to_ivar:, current_method:, namespace:, target_class:,
                                       result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        body = node.type == :class ? node.children[2] : node.children[1]
        collect_ivar_writes_per_method(body, typing: typing,
                                             attr_writer_to_ivar: attr_writer_to_ivar,
                                             current_method: nil,
                                             namespace: push_namespace(namespace, node),
                                             target_class: target_class,
                                             result: result) if body
      when :sclass
        # `class << self` — same lexical class, singleton scope; keep the
        # namespace so writes inside still attribute to the enclosing class.
        body = node.children[1]
        collect_ivar_writes_per_method(body, typing: typing,
                                             attr_writer_to_ivar: attr_writer_to_ivar,
                                             current_method: nil,
                                             namespace: namespace,
                                             target_class: target_class,
                                             result: result) if body
      when :def
        method_name = node.children[0].to_s
        body = node.children[2]
        collect_ivar_writes_per_method(body, typing: typing,
                                             attr_writer_to_ivar: attr_writer_to_ivar,
                                             current_method: method_name,
                                             namespace: namespace,
                                             target_class: target_class,
                                             result: result) if body
      when :defs
        # Singleton `def self.X` — class-instance variable scope, not
        # relevant for the per-action narrowing this method serves.
      when :ivasgn, :or_asgn, :and_asgn
        parts = ivar_write_name_and_rhs(node)
        rhs = parts&.last
        if current_method && parts && class_scope_match?(namespace, target_class)
          var_name = parts.first
          # Use the RHS's INTRINSIC type, not what `typing` recorded.
          # When the ivar is already declared in RBS (e.g.,
          # `@name: String?`), Steep's `:ivasgn` synthesize widens
          # the literal's typing via hint propagation — `@name = "TBA"`
          # shows up as `String?` instead of `String`, silently
          # swallowing the narrowing the writer actually introduces.
          # `intrinsic_type_of` re-computes the type from the literal
          # node shape, matching `synthesize(node, hint: nil)`.
          # Mirrors the same fix in Steep's
          # `Postconditions::Inferrer` (felixefelip/steep#35).
          rhs_type = intrinsic_type_of(rhs, typing)
          if rhs_type
            result[current_method][var_name].add(format_type(rhs_type))
          end
        end
        collect_ivar_writes_per_method(rhs, typing: typing,
                                            attr_writer_to_ivar: attr_writer_to_ivar,
                                            current_method: current_method,
                                            namespace: namespace,
                                            target_class: target_class,
                                            result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if current_method && attr_writer_to_ivar.key?(method_name) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           !args.empty? && class_scope_match?(namespace, target_class)
          arg = args[0]
          arg_type = intrinsic_type_of(arg, typing)
          if arg_type
            ivar = attr_writer_to_ivar.fetch(method_name)
            result[current_method][ivar].add(format_type(arg_type))
          end
        end
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                            attr_writer_to_ivar: attr_writer_to_ivar,
                                            current_method: current_method,
                                            namespace: namespace,
                                            target_class: target_class,
                                            result: result)
        end
      when :begin
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                            attr_writer_to_ivar: attr_writer_to_ivar,
                                            current_method: current_method,
                                            namespace: namespace,
                                            target_class: target_class,
                                            result: result)
        end
      else
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                            attr_writer_to_ivar: attr_writer_to_ivar,
                                            current_method: current_method,
                                            namespace: namespace,
                                            target_class: target_class,
                                            result: result)
        end
      end
    end

    # Returns the intrinsic (hint-free) type of a node. For literal AST
    # nodes Steep's `:ivasgn` synthesize widens the recorded type to
    # match the LHS declared type via hint propagation — so a
    # `@name = "TBA"` against `@name: String?` ends up with the str
    # node typed as `String?` in `typing`. The widening is intentional
    # for collections (`@x: Array[Numeric] = [1, 2, 3]` needs hint to
    # type-check), but for narrowing-detection it silently swallows
    # the writer's actual contribution.
    #
    # For literal nodes we compute the type directly from the node
    # shape, mirroring `synthesize(node, hint: nil)`. Non-literal RHS
    # nodes (sends, lvars, dstrs without interpolation, arrays, hashes)
    # fall back to `typing.type_of` — those rarely suffer the widening
    # since the hint mostly affects literal value-class lookups.
    #
    # Same pattern as `Steep::Postconditions::Inferrer#intrinsic_type_of`
    # (felixefelip/steep#35). Both call sites need to bypass the same
    # widening for the cross-receiver narrowing pipeline to fire.
    # Instance-variable writes take two AST shapes. A plain `@x = v` is an
    # `:ivasgn` carrying its RHS as the second child. A `@x ||= v` / `@x &&= v`
    # wraps an argument-less `:ivasgn` (the name alone) in an `:or_asgn` /
    # `:and_asgn` whose second child is the RHS — so walking down to the inner
    # `:ivasgn` finds no RHS, which is why `||=` writes were silently dropped
    # (felixefelip/rbs_infer#85). Returns `[name_without_@, rhs_node]` for any
    # of the three, or nil for anything else — including the bare inner
    # `:ivasgn` of an `||=`. `||=`/`&&=` assign approximately the RHS type, so
    # callers type them exactly like a plain write; `:op_asgn` (`+=`, `<<=`) is
    # deliberately excluded, since there the result type is the operator's, not
    # the RHS's.
    def ivar_write_name_and_rhs(node)
      case node.type
      when :ivasgn
        name, rhs = node.children
        [name.to_s.sub(/\A@/, ""), rhs] if rhs
      when :or_asgn, :and_asgn
        lhs, rhs = node.children
        [lhs.children[0].to_s.sub(/\A@/, ""), rhs] if lhs.type == :ivasgn && rhs
      end
    end

    def class_scope_match?(namespace, target_class)
      @steep_bridge.class_scope_match?(namespace, target_class)
    end

    def push_namespace(namespace, node)
      @steep_bridge.push_namespace(namespace, node)
    end

    def intrinsic_type_of(node, typing)
      @steep_bridge.intrinsic_type_of(node, typing)
    end

    def format_type(type)
      @steep_bridge.format_type(type)
    end
  end
end
