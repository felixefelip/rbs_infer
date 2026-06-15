module RbsInfer
  class TypeMerger
    include NodeTypeInferrer
    include KnownReturnTypesBuilder

    # Métodos de Array que retornam self (o próprio array)
    ARRAY_SELF_RETURN_METHODS = %i[<< push append unshift prepend insert concat].to_set

    def initialize(target_file:, target_class: nil, instance_types: [])
      @target_file = target_file
      @target_class = target_class
      @instance_types = instance_types
    end

    # ─── Unificar tipos de múltiplos call-sites ────────────────────────

    def merge_argument_types(usages)
      all_types = Hash.new { |h, k| h[k] = [] }

      usages.each do |usage|
        usage.each do |arg_name, type|
          all_types[arg_name] << type
        end
      end

      merged = {}
      all_types.each do |arg_name, types|
        # Preferir tipos resolvidos sobre untyped
        resolved = types.reject { |t| t == "untyped" }
        resolved = types if resolved.empty?

        # Normalizar :: prefix e deduplicar
        unique = resolved.map { |t| t.sub(/\A::/, "") }.uniq
        merged[arg_name] = unique.size == 1 ? unique.first : "(#{unique.join(" | ")})"
      end

      merged
    end

    # ─── Resolver return types de métodos que retornam attrs ────────
    # Após inferir attr_types, re-examina métodos com return "untyped"
    # e substitui pelo tipo do attr se a última expressão do método
    # for uma chamada implícita a um attr conhecido.

    def resolve_method_return_types_from_attrs(members, attr_types, method_type_resolver: nil, parsed_target: nil, method_param_types: {}, ivar_types: {})
      return unless parsed_target

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)
      # Separate surface for class methods: a `def self.x` body resolves
      # against (and feeds) class-method types only, never the instance map
      # above — otherwise a homonymous instance method's type leaks across
      # (felixefelip/rbs_infer#33).
      class_return_types = build_class_method_return_types(members, method_type_resolver: method_type_resolver, target_class: @target_class)

      # Collect mapping: [kind, method_name] -> last expression of the body
      method_last_exprs = {}
      collector = DefCollector.new(target_class: @target_class)
      parsed_target.tree.accept(collector)

      collector.defs.each do |defn|
        body = defn.body
        next unless body

        last_stmt = case body
                    when Prism::StatementsNode then body.body.last
                    else body
                    end
        next unless last_stmt

        method_name = defn.name.to_s
        # Class methods (`def self.x` or `class << self; def x`) are
        # collected as :class_method — matching the kind avoids updating the
        # wrong member when an instance and a singleton method share a name
        # (expanded CurrentAttributes accessors, or a `consume` defined both
        # ways). DefCollector carries the singleton context the bare node lacks.
        kind = collector.class_method?(defn) ? :class_method : :method
        # Resolve this body against (and write back into) the map for its
        # own kind, so class and instance methods never cross (#33).
        own_return_types = kind == :class_method ? class_return_types : known_return_types
        owner = collector.owner_of(defn)
        member = members.find { |m| m.kind == kind && m.name == method_name && m.owner == owner }
        next unless member
        next unless member.signature.end_with?("-> untyped")
        next if method_name == "initialize"

        # 0. Direct ivar read/write as the last expression
        #    (`def user; @user; end`, `def user=(v); @user = v; end`) →
        #    type already inferred for the ivar (felixefelip/rbs_infer#19)
        if last_stmt.is_a?(Prism::InstanceVariableReadNode) || last_stmt.is_a?(Prism::InstanceVariableWriteNode)
          resolved = ivar_types[last_stmt.name.to_s.sub(/\A@/, "")]
          if resolved && resolved != "untyped"
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
            next
          end
        end

        # 1. Literal na última expressão
        literal_type = infer_literal_type(last_stmt)
        if literal_type
          member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(literal_type)}")
          own_return_types[method_name] = literal_type
          next
        end

        # 2. Klass.new(...) na última expressão
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.name == :new && last_stmt.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(last_stmt.receiver)
          if class_name
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(class_name)}")
            own_return_types[method_name] = class_name
            next
          end
        end

        # 3. Chamada implícita a self (ex: `endereco` ou `process(arg)` sem receiver)
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver.nil?
          method_last_exprs[[kind, method_name]] = last_stmt.name.to_s
        end

        # 4. attr.mutation_method(expr) → return type é o tipo do attr (Array retorna self)
        if last_stmt.is_a?(Prism::CallNode) && ARRAY_SELF_RETURN_METHODS.include?(last_stmt.name) && last_stmt.receiver
          receiver_name = implicit_self_method_name(last_stmt.receiver)
          if receiver_name && own_return_types[receiver_name]
            resolved = own_return_types[receiver_name]
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
            next
          end
        end

        # 5. receiver.method() na última expressão
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver && method_type_resolver
          local_types = method_param_types[method_name] || {}
          self_ctx = self_return_type_context(known_return_types, class_return_types, kind)
          resolved = infer_call_return_type(last_stmt, self_ctx, method_type_resolver, local_types: local_types)
          if resolved
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
            next
          end
        end
      end

      # Atualizar signatures de métodos que retornam attrs/métodos conhecidos
      members.each do |member|
        next unless [:method, :class_method].include?(member.kind)
        next unless member.signature.end_with?("-> untyped")

        called_name = method_last_exprs[[member.kind, member.name]]
        next unless called_name

        # Resolve the called name against the member's own kind: a class
        # method's receiverless call refers to another class method, not a
        # homonymous instance one (#33).
        resolved_type = (member.kind == :class_method ? class_return_types : known_return_types)[called_name]
        next unless resolved_type

        member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(resolved_type)}")
      end

      # Second pass: retry chain resolution for still-untyped methods
      # (benefits from types resolved in the first pass, e.g. test_hash)
      collector.defs.each do |defn|
        body = defn.body
        next unless body

        last_stmt = case body
                    when Prism::StatementsNode then body.body.last
                    else body
                    end
        next unless last_stmt

        method_name = defn.name.to_s
        # initialize keeps `-> void` (normalized by RbsBuilder) — without
        # this skip, a trailing `self.x = param` would leak the RHS type
        # via the attribute-write rule.
        next if method_name == "initialize"
        kind = collector.class_method?(defn) ? :class_method : :method
        own_return_types = kind == :class_method ? class_return_types : known_return_types
        owner = collector.owner_of(defn)
        member = members.find { |m| m.kind == kind && m.name == method_name && m.owner == owner }
        next unless member
        next unless member.signature.end_with?("-> untyped")

        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver && method_type_resolver
          local_types = method_param_types[method_name] || {}
          self_ctx = self_return_type_context(known_return_types, class_return_types, kind)
          resolved = infer_call_return_type(last_stmt, self_ctx, method_type_resolver, local_types: local_types)
          if resolved
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
          end
        end
      end
    end

    private

    # Bundle the class's own return-type knowledge for call resolution: both
    # kind-split maps plus the enclosing method's kind. Lets a receiver typed
    # as the class being generated resolve against the right local map when no
    # RBS exists yet, without instance/class types crossing
    # (felixefelip/rbs_infer#35, guarding #33).
    def self_return_type_context(instance_types, class_types, own_kind)
      SelfReturnTypeContext.new(
        target_class: @target_class,
        instance_types: instance_types,
        class_types: class_types,
        own_kind: own_kind,
      )
    end

    # RHS type of an attribute-write call. `a&.x = v` evaluates to nil
    # when the receiver is nil, so the safe-navigation form is nilable.
    def assignment_rhs_type(call_node, self_ctx, method_type_resolver, local_types:)
      rhs = call_node.arguments&.arguments&.last
      return nil unless rhs

      type = infer_literal_type(rhs) ||
             resolve_receiver_type(rhs, self_ctx, method_type_resolver, local_types: local_types)
      return nil if type.nil? || type == "untyped"

      call_node.safe_navigation? ? RbsParserUtil.nilablize(type) : type
    end

    # Extrai nome do método quando o receiver é self implícito ou explícito
    def implicit_self_method_name(node)
      return unless node.is_a?(Prism::CallNode)
      return node.name.to_s if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    # Resolve return type de receiver.method() ou method() com args
    def infer_call_return_type(call_node, self_ctx, method_type_resolver, local_types: {})
      result = if call_node.attribute_write?
        # Assignment expression (`obj.attr = rhs`, `obj[i] = rhs`): at
        # runtime it ALWAYS evaluates to the RHS — Ruby discards the
        # setter's return value on assignment syntax (only `send`/`super`
        # observe it). Resolving via the setter's declared return here
        # leaks the wrong layer and mistypes the enclosing method.
        # Mirrors Steep's type_construction rule (soutaro/steep#243,
        # refined by #945); Prism's parser-level `attribute_write` flag
        # is the exact syntactic boundary (explicit `a.[]=(i, v)` calls
        # and `send(:x=, v)` don't carry it).
        assignment_rhs_type(call_node, self_ctx, method_type_resolver, local_types: local_types)
      elsif call_node.receiver.nil?
        # Receiverless call (implicit self). `new` is `self.new` → an
        # instance of the class being generated (felixefelip/rbs_infer#35);
        # any other name reads the enclosing self's own-kind map.
        call_node.name == :new ? self_ctx.target_class : self_ctx.own_types[call_node.name.to_s]
      elsif call_node.name == :new && call_node.receiver
        # `Foo.new` → instance of Foo; `self.new` → instance of the class
        # being generated (felixefelip/rbs_infer#35).
        RbsInfer::Analyzer.extract_constant_path(call_node.receiver) ||
          (call_node.receiver.is_a?(Prism::SelfNode) ? self_ctx.target_class : nil)
      else
        # receiver.method → resolver tipo do receiver, depois do method
        receiver_type = resolve_receiver_type(call_node.receiver, self_ctx, method_type_resolver, local_types: local_types)
        if receiver_type && receiver_type != "untyped"
          block_body_type = infer_block_body_type(call_node.block, self_ctx) if call_node.block
          constant_receiver = call_node.receiver.is_a?(Prism::ConstantReadNode) || call_node.receiver.is_a?(Prism::ConstantPathNode)
          # Use singleton lookup for constant receivers (class method calls like ActiveRecord::Base.transaction)
          resolved = if constant_receiver
                       method_type_resolver.resolve_class_method(receiver_type, call_node.name.to_s, block_body_type: block_body_type) ||
                         method_type_resolver.resolve(receiver_type, call_node.name.to_s, block_body_type: block_body_type)
                     else
                       method_type_resolver.resolve(receiver_type, call_node.name.to_s, block_body_type: block_body_type)
                     end
          resolved = receiver_type if resolved == "self"
          resolved = local_self_return(self_ctx, receiver_type, call_node.name.to_s, constant_receiver) if resolved.nil? || resolved == "untyped"
          # `a&.b` with a nilable receiver: the nil flows into the result.
          # (On a plain call the resolve is optimistic — `a.b` raises on
          # nil — but safe-nav really returns nil.)
          if resolved && call_node.safe_navigation? && receiver_type.end_with?("?")
            resolved = RbsParserUtil.nilablize(resolved)
          end
          resolved
        end
      end
      # Normalize: an instance method returning its own class → self. A class
      # (singleton) method returning an instance of its class is NOT self
      # (self there is the class), so restrict this to instance context
      # (felixefelip/rbs_infer#35).
      result = "self" if result && @target_class && result == @target_class && self_ctx.own_kind != :class_method
      result
    end

    def resolve_receiver_type(node, self_ctx, method_type_resolver, local_types: {})
      case node
      when Prism::CallNode
        if node.receiver.nil?
          # Receiverless `new` is `self.new` → an instance of the class being
          # generated; any other receiverless name reads the own-kind map
          # (felixefelip/rbs_infer#35).
          node.name == :new ? self_ctx.target_class : self_ctx.own_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          # `Foo.new` → instance of Foo; `self.new` → instance of the class
          # being generated (felixefelip/rbs_infer#35).
          RbsInfer::Analyzer.extract_constant_path(node.receiver) ||
            (node.receiver.is_a?(Prism::SelfNode) ? self_ctx.target_class : nil)
        else
          parent_type = resolve_receiver_type(node.receiver, self_ctx, method_type_resolver, local_types: local_types)
          if parent_type && parent_type != "untyped"
            resolved = method_type_resolver.resolve(parent_type, node.name.to_s)
            # "self" means the method returns the same type as the receiver
            resolved = parent_type if resolved == "self"
            if resolved.nil? || resolved == "untyped"
              constant_receiver = node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
              resolved = local_self_return(self_ctx, parent_type, node.name.to_s, constant_receiver)
            end
            resolved
          end
        end
      when Prism::SelfNode
        nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        RbsInfer::Analyzer.extract_constant_path(node)
      when Prism::LocalVariableReadNode
        local_types[node.name.to_s] || self_ctx.own_types[node.name.to_s]
      end
    end

    # Fallback for a method called on the class being generated: in
    # single-pass its RBS doesn't exist yet, so the resolver returns nil. The
    # class's own return-type maps are the local source of truth — pick the
    # one matching the RECEIVER's kind (a constant receiver → singleton
    # methods; an instance, e.g. `new`, → instance methods). Guarded by the
    # receiver type and never the method name, so a homonymous instance/class
    # method pair never crosses (felixefelip/rbs_infer#35, keeping #33 fixed).
    def local_self_return(self_ctx, receiver_type, method_name, constant_receiver)
      return nil unless self_ctx.own_class?(receiver_type)
      self_ctx.self_types_for(constant_receiver ? :singleton : :instance)[method_name]
    end

    def infer_literal_type(node)
      infer_node_type(node)
    end

    def infer_block_body_type(block_node, self_ctx)
      return nil unless block_node.is_a?(Prism::BlockNode)

      body = block_node.body
      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end
      return nil unless last_stmt

      infer_node_type(last_stmt, known_types: self_ctx.own_types, context_class: @target_class)
    end
  end
end
