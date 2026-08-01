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

    # Block — in RBS, the block goes after the closing paren, not inside it.
    #
    # A block is REQUIRED when the body cannot run without one: it `yield`s, or
    # it calls the block parameter, and it never asks whether a block is there.
    # A guard — `if block`, `block_given?`, `block&.call` — is precisely what
    # makes `?{ … }` right, so its presence is what keeps the `?`.
    #
    # Forwarding (`foo(&block)`) is NOT proof. Passing a nil block along is legal
    # Ruby, and a helper that hands its block to `tag.section` or `items.each`
    # is called without one all the time — treating the forward as a requirement
    # declares those mandatory, which is simply false.
    #
    # It leaves a gap: forwarding into a callee that DOES require a block should
    # make the forwarder require one too, and that is a transitive question this
    # class cannot answer, having no view of the callee. Recorded rather than
    # guessed at.
    #
    # Declaring every block optional made `block.call` a call on `Proc | nil`,
    # so the checker refused the one line such a method exists for. And a method
    # that only `yield`s declared no block at all, which is how a caller passing
    # one got `No block given for `yield`` (felixefelip/rbs_infer#147).
    def block_sig
      return @block_sig if defined?(@block_sig)

      @block_sig =
        if block_param_name || yields?
          required_block? ? "{ (#{block_params}) -> untyped }" : "?{ (untyped) -> untyped }"
        end
    end

    def required_block?
      (yields? || calls_block_param?) && !guards_block?
    end

    def block_param_name
      return nil unless @params.respond_to?(:block) && @params.block

      @params.block.name&.to_s
    end

    def yields?
      walk_body { |node| node.is_a?(Prism::YieldNode) }
    end

    # `block.call(…)` and `block.(…)`, which Prism spells the same.
    def calls_block_param?
      name = block_param_name or return false

      walk_body do |node|
        node.is_a?(Prism::CallNode) && node.name == :call && !node.safe_navigation? &&
          reads_block?(node.receiver, name)
      end
    end

    # The arity the body uses the block with, as `untyped` params. Fixed at one
    # before, which nothing checked while every block was optional — a required
    # block IS checked, and `login_procedure.call(token, options)` against a
    # one-parameter block is `Unexpected positional argument`. Disagreeing call
    # sites fall back to `*untyped` rather than picking a winner.
    def block_params
      arities = []
      walk_nodes do |node|
        arities << (node.arguments&.arguments&.size || 0) if node.is_a?(Prism::YieldNode)
        next unless node.is_a?(Prism::CallNode) && node.name == :call && block_param_name
        next unless reads_block?(node.receiver, block_param_name)

        arities << (node.arguments&.arguments&.size || 0)
      end

      # `*untyped` for both kinds of not-knowing: call sites that disagree, and a
      # body that only FORWARDS the block, which says nothing about its arity.
      # Defaulting those to one parameter made the forward itself a mismatch
      # against a callee that takes two.
      return "*untyped" if arities.uniq.size != 1

      Array.new(arities.first, "untyped").join(", ")
    end

    # Anything that asks whether the block is there.
    def guards_block?
      name = block_param_name

      walk_body do |node|
        next true if node.is_a?(Prism::CallNode) && node.name == :block_given?
        next false unless name
        next true if node.is_a?(Prism::CallNode) && node.safe_navigation? && reads_block?(node.receiver, name)
        next true if node.is_a?(Prism::CallNode) && node.name == :nil? && reads_block?(node.receiver, name)

        (node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)) && mentions_block?(node.predicate, name)
      end
    end

    def reads_block?(node, name)
      node.is_a?(Prism::LocalVariableReadNode) && node.name.to_s == name
    end

    def mentions_block?(node, name)
      return false unless node.is_a?(Prism::Node)
      return true if reads_block?(node, name)

      node.compact_child_nodes.any? { |child| mentions_block?(child, name) }
    end

    def walk_body(&predicate)
      return false unless @body

      RbsInfer::Analyzer.find_all_nodes(@body, &predicate).any?
    end

    def walk_nodes
      return unless @body

      RbsInfer::Analyzer.find_all_nodes(@body) { |node| yield node; false }
    end
  end
end
