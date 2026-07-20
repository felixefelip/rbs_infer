module RbsInfer::Inference
  class NewCallCollector < Prism::Visitor
    attr_reader :usages, :method_call_usages

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

    def initialize(target_class:, method_return_types:, local_var_types:, constant_arg_resolver:, defined_class_names:, method_type_resolver: nil, caller_class_name: nil, init_positional_params: [], target_methods: {}, match_bare_calls: false, self_types_by_method: {})
      @target_class = target_class
      # FQNs of classes/modules defined in the file being scanned; disambiguates
      # a relative receiver from a same-simple-name class elsewhere (see
      # `match_class?`). Required (required-threaded-deps): a forgotten wire
      # silently re-enables the cross-class conflation this guards against.
      @defined_class_names = defined_class_names
      @method_return_types = method_return_types
      @local_var_types = local_var_types
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
      @usages = []
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
      # Lexically-enclosing class names (fully qualified) and whether the
      # current method is a singleton (`def self.x`) — used to resolve a
      # `self` argument/receiver to its type.
      @class_name_stack = []
      @in_singleton_method = false
      @current_method = nil
    end

    def visit_class_node(node)
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
    end

    def visit_def_node(node)
      old_vars = @local_var_types.dup
      old_singleton = @in_singleton_method
      old_method = @current_method
      # `def self.foo` carries a receiver; plain `def foo` does not.
      @in_singleton_method = !node.receiver.nil?
      @current_method = node.name.to_s
      collect_local_assignments(node)
      super
      @current_method = old_method
      @in_singleton_method = old_singleton
      @local_var_types = old_vars
    end

    def visit_call_node(node)
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
          if receiver_type && match_class?(receiver_type)
            args = extract_cross_class_args(node, @target_methods[method_name])
            @method_call_usages[method_name] << args unless args.empty?
          end
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

    # Lookup the type of an `:ivar` reference. Tries the `@`-prefixed
    # key first (the convention used by `ErbCallerResolver` to keep
    # ivar names separate from same-basename local vars), then falls
    # back to the unprefixed key (used by `collect_class_ivar_types`
    # for in-class ivars).
    def lookup_ivar_type(node)
      full = node.name.to_s
      @local_var_types[full] || @local_var_types[full.sub(/\A@/, "")]
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
      # A marker-decorated receiver is an intersection (`Caderneta &
      # Caderneta::Validated`); match if any component is the target.
      intersection_components(name).any? do |component|
        normalized_name = component.sub(/\A::/, "")
        next true if normalized_name == normalized_target
        relative_receiver_matches_target?(normalized_name, normalized_target)
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

    def resolve_value_type(node)
      literal = RbsInfer::AST::NodeTypeInferrer.infer_literal_node_type(node, constant_resolver: @constant_arg_resolver)
      return literal if literal

      case node
      when Prism::LocalVariableReadNode
        @local_var_types[node.name.to_s] || "untyped"
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

      base = @class_name_stack.last || @caller_class_name
      return "untyped" unless base

      @in_singleton_method ? "singleton(#{base})" : base
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

      # Args posicionais
      index = 0
      call_node.arguments.arguments.each do |arg|
        break if index >= param_names.size
        next if arg.is_a?(Prism::KeywordHashNode)

        args[param_names[index]] = resolve_value_type(arg)
        index += 1
      end

      # Args keyword
      call_node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)

        arg.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          key = extract_symbol_key(elem.key)
          next unless key
          args[key] = resolve_value_type(elem.value)
        end
      end

      args
    end
  end
end
