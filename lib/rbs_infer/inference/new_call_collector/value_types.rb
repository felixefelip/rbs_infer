# frozen_string_literal: true

class RbsInfer::Inference::NewCallCollector < Prism::Visitor
  # What a node evaluates to where the collector stands (`Scope`): an argument
  # (`value_type`, `"untyped"` when unknown) or a receiver (`receiver_type`, nil
  # when unknown).
  class ValueTypes
    def initialize(scope:, method_return_types:, local_var_read_types:, method_type_resolver:, constant_arg_resolver:,
                   self_types_by_method:, module_self_types:, invoker_self_types:)
      @scope = scope
      @method_return_types = method_return_types
      @local_var_read_types = local_var_read_types
      @method_type_resolver = method_type_resolver
      @constant_arg_resolver = constant_arg_resolver
      @self_types_by_method = self_types_by_method
      @module_self_types = module_self_types
      @invoker_self_types = invoker_self_types
    end

    def value_type(node) # rubocop:todo Metrics/MethodLength
      # A hash literal is handled here, ahead of the generic literal inferrer, so its VALUES
      # resolve with what this collector knows — ivars, locals, method returns. The generic
      # inferrer builds the same record shape but sees none of that, so `{ post: @post }`
      # came out `{ post: untyped }` even where `@post` is a known `Post & Post::Validated`.
      return hash_literal_type(node) if record_shaped?(node)

      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, constant_resolver: @constant_arg_resolver)
      return literal if literal

      case node
      when Prism::LocalVariableReadNode
        lvar_read_type(node) || @scope.local_var_types[node.name.to_s] || "untyped"
      when Prism::InstanceVariableReadNode
        ivar_type(node) || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          refined_self_method_type(node.name.to_s) || @method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          method_chain_type(node) || "untyped"
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        constant_type(node)
      when Prism::SelfNode
        self_type
      when Prism::ImplicitNode
        value_type(node.value)
      else
        "untyped"
      end
    end

    # Resolver o tipo do receiver de um method call
    def receiver_type(node)
      case node
      when Prism::LocalVariableReadNode
        @scope.local_var_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        ivar_type(node)
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
          method_chain_type(node)
        end
      when Prism::SelfNode
        # self → tipo da classe léxica (instância ou singleton); nil quando
        # desconhecido, mantendo a convenção nil-returning deste método.
        resolved = self_type
        resolved == "untyped" ? nil : resolved
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # Constant receiver → singleton method call on the class
        # (`Current.user = x`, `Notifier.notify(...)`). The class name is
        # itself the receiver's "type" for match_class? purposes
        # (felixefelip/rbs_infer#19).
        RbsInfer::Analyzer.extract_constant_path(node)
      end
    end

    # See ConstantArgTypeResolver (#46).
    def constant_type(node)
      name = RbsInfer::Analyzer.extract_constant_path(node)
      @constant_arg_resolver.resolve(name: name, namespace: @scope.lexical_class_name) || "untyped"
    end

    # A non-empty hash literal whose keys are ALL plain symbols — the only shape a record
    # type can describe. Anything else (string/dynamic keys, `**splat`) keeps the generic
    # inferrer's `Hash[K, V]`, which handles those.
    def record_shaped?(node)
      return false unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      return false if node.elements.empty?

      node.elements.all? { |e| e.is_a?(Prism::AssocNode) && symbol_key(e.key) }
    end

    # `{ key: Type, ... }` for a literal keyword hash.
    def hash_literal_type(node)
      pairs = node.elements.filter_map do |e|
        next unless e.is_a?(Prism::AssocNode)

        key = symbol_key(e.key) or next
        "#{key}: #{value_type(e.value) || "untyped"}"
      end

      return "Hash[Symbol, untyped]" if pairs.empty?

      "{ #{pairs.join(", ")} }"
    end

    private

    def symbol_key(node)
      node.unescaped if node.is_a?(Prism::SymbolNode)
    end

    # Steep's type for this particular read, or nil. Prism's character column
    # matches Parser's; the byte column would drift on multibyte source.
    def lvar_read_type(node)
      @local_var_read_types[[node.location.start_line, node.location.start_character_column]]
    end

    # Lookup the type of an `:ivar` reference. Tries the `@`-prefixed
    # key first (the convention used by `ErbCallerResolver` to keep
    # ivar names separate from same-basename local vars), then falls
    # back to the unprefixed key (used by `AssignedTypes#from_class`
    # for in-class ivars).
    def ivar_type(node)
      full = node.name.to_s
      @scope.local_var_types[full] || @scope.local_var_types[full.sub(/\A@/, "")] || declared_ivar_type(full)
    end

    def declared_ivar_type(name)
      return nil unless @method_type_resolver

      class_name = @scope.lexical_class_name or return nil

      type = @method_type_resolver.resolve_ivar_types(class_name)[name]
      type if type && type != "untyped"
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
    def self_type
      # Inside an instance method covered by an after-validation callback,
      # `self` is the validated record — prefer the refined type from the
      # callback sidecar (e.g. `Caderneta & Caderneta::Validated`) over the
      # bare lexical class. Singleton methods aren't callback handlers, so
      # they keep the lexical resolution.
      unless @scope.in_singleton_method?
        refined = @scope.current_method && @self_types_by_method[@scope.current_method]
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
      return module_self_type || "untyped" if !@scope.in_singleton_method? && @scope.in_module?

      base = @scope.lexical_class_name or return "untyped"

      @scope.in_singleton_method? ? "singleton(#{base})" : base
    end

    # The answer for the module being visited. An unnameable one (a dynamic
    # constant path) falls back to the name the file stands for.
    #
    # Narrowed to the hosts that actually call THIS method. The annotators state
    # what `self` may be across the whole module — every class that includes it,
    # every one that extends it — and that is the right answer for a
    # declaration. As the type of an ARGUMENT it is too wide: `Foo#bazinga` is
    # invoked from `Bar`'s body and nowhere else, so the `self` it passes on is
    # `singleton(Bar)`, not the union with `Baz` (felixefelip/rbs_infer#222).
    def module_self_type
      declared = @module_self_types[@scope.module_name]
      return declared if declared.nil? || @scope.current_method.nil?

      @invoker_self_types.narrow(method_name: @scope.current_method, declared: declared, given: @scope.self_condition)
    end

    # Resolves a `self.<method>` against the refined `self` type when the
    # enclosing method is covered by an after-validation callback (its `self`
    # is `Model & Model::Validated`). This makes `self.<association>` resolve
    # to the marker-decorated reader (e.g. `Caderneta & Caderneta::Validated`)
    # rather than the base nilable reader. Returns nil outside such methods,
    # so the normal `@method_return_types` path is preserved unchanged.
    def refined_self_method_type(method_name)
      return nil if @scope.in_singleton_method?
      return nil unless @method_type_resolver

      refined = @scope.current_method && @self_types_by_method[@scope.current_method]
      return nil if refined.nil? || refined.empty?

      resolved = @method_type_resolver.resolve(refined, method_name, arg_types: nil)
      resolved if resolved && resolved != "untyped"
    end

    # Resolver receiver.method() → tipo do retorno do method no receiver
    def method_chain_type(node)
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

      receiver = receiver_type(node.receiver)
      return nil unless receiver && receiver != "untyped"

      resolved = @method_type_resolver.resolve(receiver, node.name.to_s, arg_types: nil)
      # `a&.b` with a nilable receiver: the nil flows into the result (on
      # a plain call the resolve is optimistic — `a.b` raises on nil).
      if resolved && node.safe_navigation? && receiver.end_with?("?")
        resolved = RbsInfer::Signatures::RbsParserUtil.nilablize(resolved)
      end
      resolved
    end
  end
end
