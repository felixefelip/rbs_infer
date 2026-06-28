class RbsInfer::Inference::ClassMemberCollector < Prism::Visitor
  class ExtractParamsSignature
    include RbsInfer::AST::NodeTypeInferrer

    def initialize(params)
			@params = params
      @parts = []
    end

    def call
      return "()" unless @params

      extract_positional_params_signature
      extract_keyword_params_signature

      result = "(#{@parts.join(", ")})"
      result = "#{result} #{block_sig}" if block_sig
      result
    end

    private

    def param_name(param)
      case param
      when Prism::RequiredParameterNode
        "untyped #{param.name}"
      else
        "untyped"
      end
    end

    def extract_positional_params_signature
      # Parâmetros posicionais obrigatórios
      @params.requireds.each do |p|
        @parts << param_name(p)
      end if @params.respond_to?(:requireds)

      # Parâmetros opcionais
      @params.optionals.each do |p|
        type = infer_node_type(p.value) if p.respond_to?(:value)
        @parts << "?#{type || 'untyped'} #{p.name}"
      end if @params.respond_to?(:optionals)

      # Rest param
      if @params.respond_to?(:rest) && @params.rest
        @parts << "*untyped"
      end
    end

    def extract_keyword_params_signature
      # Keywords obrigatórios
      @params.keywords.each do |p|
        case p
        when Prism::RequiredKeywordParameterNode
          @parts << "#{p.name}: untyped"
        when Prism::OptionalKeywordParameterNode
          @parts << "?#{p.name}: untyped"
        end
      end if @params.respond_to?(:keywords)

      # Keyword rest
      if @params.respond_to?(:keyword_rest) && @params.keyword_rest
        @parts << "**untyped"
      end
    end

    def block_sig
      # Block — in RBS, the block goes after the closing paren, not inside it
      @block_sig||= begin
        if @params.respond_to?(:block) && @params.block
          "?{ (untyped) -> untyped }"
        end
      end
    end
  end
end
