module RbsInfer::Inference
  class TypeMerger
    include RbsInfer::AST::NodeTypeInferrer
    include KnownReturnTypesBuilder

    # Métodos de Array que retornam self (o próprio array)
    ARRAY_SELF_RETURN_METHODS = %i[<< push append unshift prepend insert concat].to_set

    attr_reader :constant_resolver

    # constant_resolver: env-aware resolver so a constant in value position
    # (e.g. a block body) is typed by its VALUE, not its bare name (#56).
    def initialize(target_file:, constant_resolver:, target_class: nil, instance_types: [])
      @target_file = target_file
      @constant_resolver = constant_resolver
      @target_class = target_class
      @instance_types = instance_types
    end

    # ─── Unificar tipos de múltiplos call-sites ────────────────────────

    # Unions a list of types (from distinct call-sites) into a single RBS
    # string. `untyped` is dropped when at least one resolved type exists.
    # Pre-existing unions (`(String | Symbol)`) are flattened via the RBS
    # parser, so combining partial results (intra-class + cross-class) is
    # associative and idempotent — no nested parens, no duplicate members.
    def self.union_types(types)
      flat = types.flat_map { |t| flatten_union(t) }

      # Prefer resolved types over untyped
      resolved = flat.reject { |t| t == "untyped" }
      resolved = flat if resolved.empty?

      # Dedup by the canonical form, keeping the original spelling of the first
      # occurrence — a single type is emitted verbatim, so absolute names
      # (`::MyApp::Entity`) stay intact.
      seen = {}
      unique = []
      resolved.each do |type|
        key = canonical_key(type)
        next if seen[key]
        seen[key] = true
        unique << type
      end
      unique = collapse_subsumed(unique)
      unique.size == 1 ? unique.first : "(#{unique.join(" | ")})"
    end

    # Drops members another member already covers — which de-duplication can't
    # catch, because the two are genuinely different types that happen to nest:
    # `bool` contains both constants, `true | false` spans all of it, and a
    # literal is a subtype of its own class, so `String | ""` IS `String`.
    #
    # All three shapes come from a call on a nilable receiver, whose two branches
    # answer with opposite constants: `ActiveRecord::Core#present?: () -> true`
    # against `NilClass#present?: () -> false`, `Object#present?: () -> bool`
    # against that same `false`, `Integer#to_s: () -> String` against
    # `NilClass#to_s: () -> ""`. Left alone they'd emit a union where the plain
    # type is both shorter and exactly as precise.
    def self.collapse_subsumed(members)
      return members if members.size < 2

      keys = members.to_h { |m| [m, canonical_key(m)] }

      if keys.value?("bool")
        members = members.reject { |m| %w[true false].include?(keys[m]) }
      elsif keys.value?("true") && keys.value?("false")
        members = members.map { |m| keys[m] == "true" ? "bool" : m }.reject { |m| keys[m] == "false" }
      end

      covered = members.map { |m| canonical_key(m) }.to_set
      members.reject { |m| (cls = literal_class_name(m)) && covered.include?(cls) }
    end

    # The class a literal type is an instance of ("String" for `""`), or nil
    # when the type isn't a literal. `true`/`false` are literals too, but they
    # are handled by the `bool` rule above — TrueClass/FalseClass are not how
    # RBS spells that union.
    def self.literal_class_name(type)
      parsed = RBS::Parser.parse_type(type)
      return nil unless parsed.is_a?(RBS::Types::Literal)

      case parsed.literal
      when ::String then "String"
      when ::Symbol then "Symbol"
      when ::Integer then "Integer"
      end
    rescue RBS::ParsingError, RBS::BaseError
      nil
    end

    # The identity of a type for dedup purposes, so two SPELLINGS of one type collapse.
    # A textual key does not: the same intersection reaches the merger as
    # `(Post & Post::Validated)` when read back from an RBS declaration and as
    # `Post & Post::Validated` from Steep, and unioning them yielded
    # `((Post & Post::Validated) | Post & Post::Validated)`. The RBS parser already
    # canonicalizes redundant parens; the `::` strip stays because it is a naming
    # convention (cross-class output omits the prefix), not something the parser touches.
    def self.canonical_key(type)
      RBS::Parser.parse_type(type).to_s.sub(/\A::/, "")
    rescue RBS::ParsingError, RBS::BaseError
      type.sub(/\A::/, "")
    end

    # Flattens a type into its set of top-level union members.
    # `(String | Symbol)` → `["String", "Symbol"]`; non-union types (incl.
    # generics like `Array[A | B]`) are left intact.
    def self.flatten_union(type_str)
      parsed = RBS::Parser.parse_type(type_str)
      parsed.is_a?(RBS::Types::Union) ? parsed.types.map(&:to_s) : [type_str]
    rescue RBS::ParsingError, RBS::BaseError
      [type_str]
    end

    def merge_argument_types(usages)
      all_types = Hash.new { |h, k| h[k] = [] }

      usages.each do |usage|
        usage.each do |arg_name, type|
          all_types[arg_name] << type
        end
      end

      merged = {}
      all_types.each do |arg_name, types|
        # Cross-class convention: emit names without the absolute `::` prefix,
        # so `::Shared::Cpf` and `Shared::Cpf` collapse into one.
        normalized = types.map { |t| t.sub(/\A::/, "") }
        merged[arg_name] = self.class.union_types(normalized)
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
      collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
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
        # A record assembled by the syntax-only pass may retain an `untyped`
        # field even though the RHS of its enclosing assignment is resolvable.
        # Keep those members in this pass so an indexed write such as
        # `cookies[:token] = { value: session.signed_id }` can refine the
        # record from the typed RHS rather than from the (untyped) writer.
        next unless member.signature.end_with?("-> untyped") || unresolved_record_return?(member.signature)
        next if method_name == "initialize"

        # The same identity the member lookup above uses, applied to the
        # inferred-parameter table: a nested module's method reads ITS call
        # sites, not those of a homonym in a sibling module
        # (felixefelip/rbs_infer#215).
        param_types = inferred_param_types(method_param_types, method_name, owner, kind)

        # 0. Direct ivar read/write as the last expression
        #    (`def user; @user; end`, `def user=(v); @user = v; end`) →
        #    type already inferred for the ivar (felixefelip/rbs_infer#19)
        if last_stmt.is_a?(Prism::InstanceVariableReadNode) || last_stmt.is_a?(Prism::InstanceVariableWriteNode)
          resolved = ivar_types[last_stmt.name.to_s.sub(/\A@/, "")]
          resolved = assigned_param_type(last_stmt, param_types) if resolved.nil? || resolved == "untyped"
          if resolved && resolved != "untyped"
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
            next
          end
        end

        # 1. Literal na última expressão
        literal_type = infer_literal_type(last_stmt)
        if literal_type
          member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(literal_type)}")
          own_return_types[method_name] = literal_type
          next
        end

        # 2. A constructor call as the last expression — all three spellings,
        #    `Klass.new`, `self.new` and a BARE `new`, resolved by the one rule
        #    `infer_call_return_type` already applies further down a chain.
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.name == :new
          class_name = constructed_class(last_stmt, kind, method_type_resolver)
          if class_name
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(class_name)}")
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
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
            next
          end
        end

        # 5. receiver.method() na última expressão
        if last_stmt.is_a?(Prism::CallNode) && last_stmt.receiver && method_type_resolver
          self_ctx = self_return_type_context(known_return_types, class_return_types, kind)
          resolved = infer_call_return_type(last_stmt, self_ctx, method_type_resolver, local_types: param_types)
          if resolved
            replace_return_type(member, resolved)
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

        member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(resolved_type)}")
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
          local_types = inferred_param_types(method_param_types, method_name, owner, kind)
          self_ctx = self_return_type_context(known_return_types, class_return_types, kind)
          resolved = infer_call_return_type(last_stmt, self_ctx, method_type_resolver, local_types: local_types)
          if resolved
            member.signature = member.signature.sub(/-> untyped\z/, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(resolved)}")
            own_return_types[method_name] = resolved
          end
        end
      end
    end

    private

    # The parameter types inferred for the method identified by (name, owner,
    # kind) — `owner` relative to the target, as `DefCollector` reports it.
    def inferred_param_types(method_param_types, method_name, owner, kind)
      RbsInfer::Inference::MethodKey.lookup(
        method_param_types,
        method_name,
        owner: RbsInfer::Inference::MethodKey.qualify_owner(@target_class, owner),
        kind: kind
      ) || {}
    end

    # `@x = value` evaluates to VALUE — that is what Ruby returns, whatever the
    # ivar was declared as — so the parameter answers when the ivar map cannot.
    #
    # It cannot for a SINGLETON setter, which is where every `-> untyped` setter
    # in the dummy came from: `def self.user=(value); @user = value; end` writes
    # a class-instance variable (`self.@user`), a different slot from the
    # instance ivars this pass is given. Steep types the method
    # `Example18::User` all along (felixefelip/rbs_infer#154).
    #
    # Instance setters reach it too, whenever the ivar map has no answer yet.
    # The parameter is the more precise source there: an `@user: Widget?` whose
    # setter takes a `Widget` returns a `Widget`, never nil. The ivar keeps
    # precedence only because it is the established behaviour for the READ half
    # of this rule, where it is the right answer.
    #
    # Narrow on purpose: only a bare parameter read. `@x = compute(value)` is
    # someone else's question, and guessing it here would be worse than leaving
    # the honest `untyped`.
    def assigned_param_type(node, local_types)
      return nil unless node.is_a?(Prism::InstanceVariableWriteNode)

      value = node.value
      return nil unless value.is_a?(Prism::LocalVariableReadNode)

      local_types[value.name.to_s]
    end

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

      type = resolved_record_type(rhs, self_ctx, method_type_resolver, local_types: local_types) ||
             infer_literal_type(rhs) ||
             resolve_receiver_type(rhs, self_ctx, method_type_resolver, local_types: local_types)
      return nil if type.nil? || type == "untyped"

      call_node.safe_navigation? ? RbsInfer::Signatures::RbsParserUtil.nilablize(type) : type
    end

    # The generic type of an assignment expression follows its writer, which is
    # often `untyped` for framework objects (e.g. `cookies[...] = value`). Ruby
    # nevertheless evaluates assignment syntax to its RHS. For record RHSs,
    # resolve each field here so calls such as `session.signed_id` don't remain
    # `untyped` merely because they are nested inside a hash literal.
    def resolved_record_type(node, self_ctx, method_type_resolver, local_types:)
      return unless node.is_a?(Prism::HashNode)
      return if node.elements.any? { |element| element.is_a?(Prism::AssocSplatNode) }

      assocs = node.elements.select { |element| element.is_a?(Prism::AssocNode) }
      return if assocs.empty? || !assocs.all? { |assoc| assoc.key.is_a?(Prism::SymbolNode) }

      pairs = assocs.map do |assoc|
        type = infer_literal_type(assoc.value) ||
               resolve_receiver_type(assoc.value, self_ctx, method_type_resolver, local_types: local_types)
        return if type.nil? || type == "untyped"

        "#{assoc.key.unescaped}: #{type}"
      end

      "{ #{pairs.join(", ")} }"
    end

    def unresolved_record_return?(signature)
      signature.match?(/-> \{.*\buntyped\b.*\}\z/)
    end

    # The trailing return type, and only that. `-> .+\z` is greedy AND
    # leftmost, so it matched from the FIRST arrow: a signature carrying a block
    # (`() { (Integer) -> void } -> untyped`) came out as
    # `() { (Integer) -> String`, unbalanced and unparseable.
    #
    # The alternation names exactly the two shapes that can reach here — the
    # original `-> untyped`, and the partially resolved record
    # `-> { value: untyped }` — and both are anchored at the end, so an arrow
    # inside a block type can never be the match. A signature matching neither
    # is left alone rather than mangled.
    RETURN_TYPE_SUFFIX = /-> (?:untyped|\{.*\})\z/

    def replace_return_type(member, type)
      member.signature = member.signature.sub(RETURN_TYPE_SUFFIX, "-> #{RbsInfer::Signatures::RbsParserUtil.parenthesize_union(type)}")
    end

    # Extrai nome do método quando o receiver é self implícito ou explícito
    def implicit_self_method_name(node)
      return unless node.is_a?(Prism::CallNode)
      return node.name.to_s if node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    # The class a constant receiver names, resolved the way Ruby resolves it:
    # from the enclosing class outward, so `Archiver.new(...)` written inside
    # `Post` is `Post::Archiver` when that exists (felixefelip/rbs_infer#129).
    # `@target_class` IS the lexical scope of every body this merger walks.
    # The class a `new` call constructs. `Klass.new` names its own class;
    # `self.new` and a bare `new` are the same call in a class-method body,
    # where `self` IS the class, so both construct the class being generated
    # (felixefelip/rbs_infer#35).
    #
    # Nil in an instance method for the two self-spellings: there `self` is an
    # instance, so a receiverless `new` is an ordinary method call and
    # answering `@target_class` would invent a constructor.
    #
    # The bare form is what a factory written in `class << self` uses
    # (`def for(x); ...; new(...); end`). It used to fall past this rule into
    # the receiverless-call case below, which asks the name map for `new` —
    # empty on a cold start, because that map's RBS half is the class's OWN
    # previously-generated signature. The method was then left `-> untyped`
    # for Steep, and Steep cannot answer while the class has no RBS either: it
    # resolved `new` against `::Object` and typed the factory `Object`. Once
    # `-> Object?` was written it was permanent, because every later pass only
    # reconsiders members still `untyped` — so whatever the FIRST generation of
    # a file guessed decided the type forever, and deleting the `.rbs` to
    # regenerate made it worse rather than better.
    def constructed_class(call_node, kind, method_type_resolver)
      receiver = call_node.receiver

      if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        @target_class if kind == :class_method
      else
        constant_receiver_class(receiver, method_type_resolver)
      end
    end

    def constant_receiver_class(node, method_type_resolver)
      name = RbsInfer::Analyzer.extract_constant_path(node) or return nil
      return name unless method_type_resolver

      method_type_resolver.qualify_constant(name, enclosing: @target_class)
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
        constant_receiver_class(call_node.receiver, method_type_resolver) ||
          (call_node.receiver.is_a?(Prism::SelfNode) ? self_ctx.target_class : nil)
      else
        # receiver.method → resolver tipo do receiver, depois do method
        receiver_type = resolve_receiver_type(call_node.receiver, self_ctx, method_type_resolver, local_types: local_types)
        if receiver_type && receiver_type != "untyped"
          block_body_type = infer_block_body_type(call_node.block, self_ctx) if call_node.block
          constant_receiver = call_node.receiver.is_a?(Prism::ConstantReadNode) || call_node.receiver.is_a?(Prism::ConstantPathNode)
          # Use singleton lookup for constant receivers (class method calls like ActiveRecord::Base.transaction)
          arg_types = argument_types(call_node, self_ctx, method_type_resolver, local_types: local_types)
          resolved = if constant_receiver
                       method_type_resolver.resolve_class_method(receiver_type, call_node.name.to_s, block_body_type: block_body_type) ||
                         method_type_resolver.resolve(receiver_type, call_node.name.to_s, block_body_type: block_body_type,
                                                                                          arg_types: arg_types)
                     else
                       method_type_resolver.resolve(receiver_type, call_node.name.to_s, block_body_type: block_body_type,
                                                                                        arg_types: arg_types)
                     end
          resolved = receiver_type if resolved == "self"
          resolved = local_self_return(self_ctx, receiver_type, call_node.name.to_s, constant_receiver) if resolved.nil? || resolved == "untyped"
          # `a&.b` with a nilable receiver: the nil flows into the result.
          # (On a plain call the resolve is optimistic — `a.b` raises on
          # nil — but safe-nav really returns nil.)
          if resolved && call_node.safe_navigation? && receiver_type.end_with?("?")
            resolved = RbsInfer::Signatures::RbsParserUtil.nilablize(resolved)
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

    # The call's POSITIONAL argument types, or nil when the list is not one this
    # can answer whole. An overload is only picked when every argument is known,
    # so a partial answer is worth nothing — and `nil` is the difference between
    # "the arguments say this overload" and "say nothing", which is what keeps
    # the selection sound.
    #
    # Splats, block-passes, keywords and forwarding all decline: they describe
    # an argument list this array cannot stand for.
    def argument_types(call_node, self_ctx, method_type_resolver, local_types: {})
      arguments = call_node.arguments&.arguments
      return nil if arguments.nil? || arguments.empty?
      return nil unless arguments.all? { |argument| positional_argument?(argument) }

      types = arguments.map do |argument|
        argument_type(argument, self_ctx, method_type_resolver, local_types: local_types)
      end
      types.any?(&:nil?) ? nil : types
    end

    # A CONSTANT in argument position is the class OBJECT — `singleton(Foo)` —
    # which is the opposite of what `resolve_receiver_type` answers for it: as a
    # RECEIVER a constant names the class whose singleton is being called, so it
    # returns the bare `Foo`. Handing that to the selection would match an
    # overload taking an INSTANCE. Decline instead; a wrong type here is exactly
    # the failure this whole path exists to remove.
    def argument_type(node, self_ctx, method_type_resolver, local_types: {})
      return nil if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      infer_literal_type(node) ||
        resolve_receiver_type(node, self_ctx, method_type_resolver, local_types: local_types)
    end

    def positional_argument?(node)
      !(node.is_a?(Prism::SplatNode) || node.is_a?(Prism::BlockArgumentNode) ||
        node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::ForwardingArgumentsNode))
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
          constant_receiver_class(node.receiver, method_type_resolver) ||
            (node.receiver.is_a?(Prism::SelfNode) ? self_ctx.target_class : nil)
        else
          parent_type = resolve_receiver_type(node.receiver, self_ctx, method_type_resolver, local_types: local_types)
          if parent_type && parent_type != "untyped"
            resolved = method_type_resolver.resolve(parent_type, node.name.to_s, arg_types: nil)
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
        constant_receiver_class(node, method_type_resolver)
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
      # A constant reference is not a literal: its type is the constant's VALUE
      # type (a value constant like `CONTINUE` → `Integer`) or `singleton(K)`
      # for a class/module — never the bare name `infer_node_type` yields, which
      # is invalid RBS for the former and wrong for the latter. Defer to the
      # Steep-backed return pass in `improve_method_return_types`, leaving the
      # method `-> untyped` for now (felixefelip/rbs_infer#46).
      return nil if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

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
