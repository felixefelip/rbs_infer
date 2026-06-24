module RbsInfer
  # Resolve return types de métodos e tipos de instance variables
  # a partir de análise estática do corpo dos métodos.
  #
  # Extraído de Analyzer para manter responsabilidades separadas:
  # - improve_method_return_types: resolve return types de métodos via chain resolution
  # - infer_ivar_types: infere tipos de instance variables (@post, @posts, etc.)

  class ReturnTypeResolver
    include KnownReturnTypesBuilder

    def initialize(target_file:, target_class:, method_type_resolver:, instance_types: [], steep_bridge: nil)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
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
          collector = RbsInfer::AST::DefCollector.new
          parsed_target.tree.accept(collector)
          def_map = {}
          collector.defs.each { |d| def_map[d.name.to_s] = d if d.is_a?(Prism::DefNode) }

          self_types = Set.new([@target_class] + @instance_types)

          still_untyped.each do |m|
            next if setter_name?(m.name)
            steep_type = steep_returns_for(m, steep_returns)[m.name]
            if steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
              # Instance methods returning the same class (or host class for concerns) → self
              steep_type = "self" if self_types.include?(steep_type)

              # Check for early return nil in body
              defn = def_map[m.name]
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

            steep_type = "self" if self_types.include?(steep_type)

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
      return {} unless parsed_target

      # Nomes de attrs já declarados (attr_accessor, attr_reader) → pular
      attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                          .map(&:name).to_set

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
        steep_ivars = @steep_bridge.ivar_write_types(parsed_target.source)
        steep_ivars.each do |name, type|
          next if attr_names.include?(name)
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

      collector = RbsInfer::AST::DefCollector.new
      parsed_target.tree.accept(collector)

      initialized_ivars = collect_prism_initialized_ivars(parsed_target.tree)
      fallback_type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }

      collector.defs.each do |defn|
        param_types = method_param_types[defn.name.to_s] || {}
        collect_ivar_writes(defn, known_return_types, fallback_type_sets, attr_names, param_types: param_types)
      end

      fallback_type_sets.each do |name, type_set|
        next if ivar_types.key?(name)
        force_nilable = !initialized_ivars.include?(name) || steep_nil_only.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        if emitted
          ivar_types[name] = emitted
          known_return_types[name] = emitted
        end
      end

      ivar_types
    end

    private

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

    # Verifica se o corpo do método contém `return nil` ou `return` (implícito nil)
    def has_nil_return?(defn)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
    end

    def collect_ivar_writes(node, known_return_types, type_sets, attr_names, param_types: {})
      queue = [node]
      while (current = queue.shift)
        if current.is_a?(Prism::InstanceVariableWriteNode)
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
    # are assigned inside `def initialize` or directly in the class body
    # (outside any method). Mirrors `SteepBridge#collect_initialized_ivars`
    # for the Prism path. Used by the definite-initialization rule
    # (felixefelip/rbs_infer#4).
    def collect_prism_initialized_ivars(tree)
      result = Set.new
      walk_prism_init_targets(tree, in_init: false, in_class_body: false, result: result)
      result
    end

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
      case node
      when Prism::NilNode then "nil"
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then RbsInfer::AST::NodeTypeInferrer.infer_hash_type(node, known_types: known_return_types, context_class: @target_class)
      when Prism::SelfNode then @target_class
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
        elsif node.receiver.nil?
          known_return_types[node.name.to_s]
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      end
    end
  end
end
