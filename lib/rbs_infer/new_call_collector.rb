module RbsInfer
  class Analyzer
  class NewCallCollector < Prism::Visitor
    attr_reader :usages, :method_call_usages

    AR_FINDER_METHODS = %i[find find_by find_by! first first! last last! take take! create create! find_or_create_by find_or_create_by! find_sole_by].freeze

    def initialize(target_class:, method_return_types:, local_var_types:, method_type_resolver: nil, caller_class_name: nil, init_positional_params: [], target_methods: {})
      @target_class = target_class
      @method_return_types = method_return_types
      @local_var_types = local_var_types
      @method_type_resolver = method_type_resolver
      @caller_class_name = caller_class_name
      @init_positional_params = init_positional_params
      @target_methods = target_methods
      @usages = []
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
    end

    def visit_class_node(node)
      # Pré-coletar tipos de ivars de todos os métodos da classe
      # para que @post definido em set_post esteja disponível em publish
      collect_class_ivar_types(node)
      super
    end

    def visit_def_node(node)
      old_vars = @local_var_types.dup
      collect_local_assignments(node)
      super
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

      super
    end

    private

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
        elsif AR_FINDER_METHODS.include?(call.name) && call.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(call.receiver)
          @local_var_types[var_name] = class_name if class_name
        end
      end
    end

    def match_class?(name)
      normalized_target = @target_class.sub(/\A::/, "")
      normalized_name = name.sub(/\A::/, "")
      # Match exato ou referência relativa (ex: Email == Academico::Aluno::Email)
      normalized_name == normalized_target ||
        normalized_target.end_with?("::#{normalized_name}")
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
            elsif AR_FINDER_METHODS.include?(stmt.value.name) && stmt.value.receiver
              # record = Record.find_by!(...) → type Record
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              @local_var_types[var_name] = class_name if class_name
            end
          end
        elsif stmt.is_a?(Prism::InstanceVariableWriteNode)
          var_name = stmt.name.to_s.sub(/\A@/, "")
          if stmt.value.is_a?(Prism::CallNode)
            if stmt.value.name == :new && stmt.value.receiver
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              @local_var_types[var_name] = class_name if class_name
            elsif AR_FINDER_METHODS.include?(stmt.value.name) && stmt.value.receiver
              class_name = RbsInfer::Analyzer.extract_constant_path(stmt.value.receiver)
              @local_var_types[var_name] = class_name if class_name
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
      case node
      when Prism::LocalVariableReadNode
        @local_var_types[node.name.to_s] || "untyped"
      when Prism::InstanceVariableReadNode
        @local_var_types[node.name.to_s.sub(/\A@/, "")] || "untyped"
      when Prism::CallNode
        if node.receiver.nil?
          @method_return_types[node.name.to_s] || "untyped"
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
        else
          resolve_method_chain(node) || "untyped"
        end
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then "Hash[untyped, untyped]"
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        RbsInfer::Analyzer.extract_constant_path(node) || "untyped"
      when Prism::ImplicitNode
        resolve_value_type(node.value)
      else
        "untyped"
      end
    end

    # Resolver receiver.method() → tipo do retorno do method no receiver
    def resolve_method_chain(node)
      return nil unless @method_type_resolver

      receiver_type = resolve_receiver_type(node.receiver)
      return nil unless receiver_type && receiver_type != "untyped"

      @method_type_resolver.resolve(receiver_type, node.name.to_s)
    end

    # Resolver o tipo do receiver de um method call
    def resolve_receiver_type(node)
      case node
      when Prism::LocalVariableReadNode
        @local_var_types[node.name.to_s]
      when Prism::InstanceVariableReadNode
        @local_var_types[node.name.to_s.sub(/\A@/, "")]
      when Prism::CallNode
        if node.receiver.nil?
          # Implicit method call (ex: attr_reader como aluno_dto)
          @method_return_types[node.name.to_s]
        elsif node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        else
          resolve_method_chain(node)
        end
      when Prism::SelfNode
        nil # self → seria a própria classe, não resolvemos por enquanto
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
end
