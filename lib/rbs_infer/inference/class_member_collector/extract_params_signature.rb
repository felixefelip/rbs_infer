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

    # Structural: constant defaults are captured into @constant_default_params and
    # emitted as `?untyped` for the Analyzer to fill, so this never resolves a
    # value-position constant itself (felixefelip/rbs_infer#56).
    def constant_resolver = nil

    # `body` decides whether a block is required, and whether a method that only
    # `yield`s takes one at all — neither is visible from the parameters alone.
    def initialize(params, body: nil)
			@params = params
      @body = body
      @parts = []
      @constant_default_params = {}
    end

    def call
      if @params
        extract_positional_params_signature
        extract_keyword_params_signature
      end

      result = "(#{@parts.join(", ")})"
      block_sig ? "#{result} #{block_sig}" : result
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
      when Prism::NilNode
        # A `nil` default says the parameter is OPTIONAL, not that its type is `nil`.
        # Taking it literally emits `?nil`, which means "you may only ever pass nil" and
        # rejects every real call — `def render(target = nil)` typed `?nil target` made
        # `render :edit` fail with "Cannot pass ::Symbol as an argument of type nil".
        # Nothing is lost by widening: a parameter genuinely only ever passed nil is
        # degenerate, and `untyped` still admits it.
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

    # The block half lives in its own object: it is decided by the BODY, not
    # by the parameter list, and it is about to learn more (the callee's own
    # requirement, the types at the use sites) that has no business here.
    def block_sig
      return @block_sig if defined?(@block_sig)

      @block_sig = BlockSignature.new(@params, body: @body).call
    end
  end
end
