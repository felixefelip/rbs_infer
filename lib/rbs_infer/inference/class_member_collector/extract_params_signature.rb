class RbsInfer::Inference::ClassMemberCollector < Prism::Visitor
  class ExtractParamsSignature
    include RbsInfer::AST::NodeTypeInferrer

    # Optional positional params whose default is a constant reference, mapped
    # `name => Prism node`. A constant's VALUE type (`Array[String]`, `Integer`,
    # …) is not its bare name — a bare name is a valid type only for a
    # class/module — so we can't resolve it here (no SteepBridge/env). We emit
    # `?untyped name` and let the Analyzer fill it via ConstantArgTypeResolver,
    # mirroring how `:constant` members defer (felixefelip/rbs_infer#37, #46).
    attr_reader :constant_default_params

    def initialize(params)
			@params = params
      @parts = []
      @constant_default_params = {}
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

    def optional_param_type(param)
      value = param.value if param.respond_to?(:value)

      case value
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        @constant_default_params[param.name.to_s] = value
        "untyped"
      else
        infer_node_type(value) || "untyped"
      end
    end

    def extract_positional_params_signature
      # Parâmetros posicionais obrigatórios
      @params.requireds.each do |p|
        @parts << param_name(p)
      end if @params.respond_to?(:requireds)

      # Parâmetros opcionais
      @params.optionals.each do |p|
        @parts << "?#{optional_param_type(p)} #{p.name}"
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
