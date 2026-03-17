module RbsInfer
  # Analisa chamadas intra-classe para inferir tipos de parâmetros de métodos privados.
  # Duas estratégias:
  # 1. Caller-side: em `call`, `publicar_evento(aluno:)` onde `aluno = Entity.new(...)` →
  #    infere que `publicar_evento` tem `aluno: Academico::Aluno::Entity`
  # 2. Usage-side: em `adicionar_telefone(ddd:, numero:)`, o corpo faz
  #    `Telefone.new(ddd:, numero:)` → infere `ddd: String, numero: String`
  #    a partir da assinatura de Telefone#initialize
  class IntraClassCallAnalyzer < Prism::Visitor
    include NodeTypeInferrer
    # method_name → { param_name → type }
    attr_reader :inferred_param_types

    def initialize(attr_types: {}, method_type_resolver: nil, method_positional_params: {}, steep_bridge: nil, source_code: nil)
      @attr_types = attr_types
      @method_type_resolver = method_type_resolver
      @inferred_param_types = Hash.new { |h, k| h[k] = {} }
      @local_var_types = {}
      @current_method_name = nil
      @current_param_names = Set.new
      @method_positional_params = method_positional_params
      @steep_local_var_types = steep_bridge && source_code ? steep_bridge.local_var_types_per_method(source_code) : {}
    end

    def visit_def_node(node)
      old_vars = @local_var_types.dup
      old_method = @current_method_name
      old_params = @current_param_names

      @local_var_types = {}
      @current_method_name = node.name.to_s
      @current_param_names = extract_param_names(node.parameters)

      # Merge Steep-inferred types first, then overlay manual collection
      steep_vars = @steep_local_var_types[@current_method_name]
      @local_var_types.merge!(steep_vars) if steep_vars

      collect_local_assignments(node)
      super

      @local_var_types = old_vars
      @current_method_name = old_method
      @current_param_names = old_params
    end

    def visit_call_node(node)
      if node.receiver.nil? && node.arguments
        method_name = node.name.to_s

        # Keyword args
        args = extract_keyword_arg_types(node)
        args.each do |param_name, type|
          next if type == "untyped"
          existing = @inferred_param_types[method_name][param_name]
          @inferred_param_types[method_name][param_name] = type unless existing
        end

        # Positional args: mapear por posição usando os nomes dos parâmetros do método-alvo
        positional_params = @method_positional_params[method_name]
        if positional_params
          positional_args = node.arguments.arguments.reject { |a| a.is_a?(Prism::KeywordHashNode) }
          positional_args.each_with_index do |arg, i|
            param_name = positional_params[i]
            next unless param_name
            type = resolve_value_type(arg)
            next if type == "untyped"
            existing = @inferred_param_types[method_name][param_name]
            @inferred_param_types[method_name][param_name] = type unless existing
          end
        end
      end

      # Usage-side: Klass.new(param:) dentro do corpo do método
      if @current_method_name && node.name == :new && node.receiver && node.arguments
        infer_param_types_from_new_call(node)
      end

      super
    end

    private

    def extract_param_names(params)
      return Set.new unless params
      names = Set.new
      params.keywords.each { |kw| names << kw.name.to_s } if params.respond_to?(:keywords)
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
      names
    end

    # Quando o corpo de um método faz Klass.new(param:, param2:) e os valores
    # são parâmetros do método, inferir os tipos dos parâmetros via a assinatura
    # de Klass#initialize (resolve_init_param_types)
    def infer_param_types_from_new_call(node)
      return unless @method_type_resolver

      class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
      return unless class_name

      # Usar resolve_all que retorna tipos de attrs/methods (inclui anotações e inferência)
      class_types = @method_type_resolver.resolve_all(class_name)
      return if class_types.empty?

      node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)

        arg.elements.each do |elem|
          next unless elem.is_a?(Prism::AssocNode)
          key = extract_symbol_key(elem.key)
          next unless key

          # Verificar se o valor é um parâmetro do método atual (shorthand `param:` ou `param: param`)
          value_param = extract_param_reference(elem.value)
          next unless value_param && @current_param_names.include?(value_param)

          # Tipo esperado por Klass para esse kwarg (via attrs/methods da classe)
          expected_type = class_types[key]
          next unless expected_type && expected_type != "untyped"

          existing = @inferred_param_types[@current_method_name][value_param]
          @inferred_param_types[@current_method_name][value_param] = expected_type unless existing
        end
      end
    end

    # Retorna o nome do parâmetro se o nó é uma referência a um parâmetro
    def extract_param_reference(node)
      case node
      when Prism::LocalVariableReadNode
        name = node.name.to_s
        name if @current_param_names.include?(name)
      when Prism::ImplicitNode
        extract_param_reference(node.value)
      end
    end

    def collect_local_assignments(defn)
      body = defn.body
      return unless body

      stmts = case body
              when Prism::StatementsNode then body.body
              else [body]
              end

      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          type = infer_expression_type(stmt.value)
          @local_var_types[stmt.name.to_s] = type if type
        end
      end
    end

    def infer_expression_type(node)
      basic = infer_node_type(node)
      return basic if basic

      case node
      when Prism::CallNode
        if node.receiver.nil?
          @attr_types[node.name.to_s]
        elsif node.receiver.is_a?(Prism::LocalVariableReadNode)
          var_type = @local_var_types[node.receiver.name.to_s]
          if var_type && @method_type_resolver
            @method_type_resolver.resolve(var_type, node.name.to_s)
          end
        end
      end
    end

    def extract_keyword_arg_types(call_node)
      args = {}
      call_node.arguments.arguments.each do |arg|
        case arg
        when Prism::KeywordHashNode
          arg.elements.each do |elem|
            next unless elem.is_a?(Prism::AssocNode)
            key = extract_symbol_key(elem.key)
            next unless key
            type = resolve_value_type(elem.value)
            args[key] = type if type
          end
        end
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
      when Prism::ImplicitNode
        resolve_value_type(node.value)
      when Prism::CallNode
        infer_expression_type(node) || "untyped"
      else
        infer_node_type(node) || "untyped"
      end
    end
  end
end
