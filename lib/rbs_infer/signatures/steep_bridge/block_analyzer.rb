class RbsInfer::Signatures::SteepBridge
  class BlockAnalyzer
    def initialize(steep_bridge:)
			@steep_bridge = steep_bridge
    end

    # Methods that hand their own block to someone else, mapped to what that
    # callee declares the block to be:
    #
    #   { "authenticate_with_http_token" => { required: true, params: ["String", "…?"] } }
    #
    # Forwarding proves nothing by itself — `items.each(&block)` is perfectly
    # fine without a block — so the answer has to come from the CALLEE, and only
    # the checker can say which of its overloads applies. Against a possibly-nil
    # proc it picks `() -> ::Enumerator[Elem, self]` for `each` (no block
    # required) and the single required-block declaration for
    # `Token.authenticate`. That is the distinction rbs_infer cannot draw
    # structurally, and the reason this lives here (felixefelip/rbs_infer#149).
    #
    # Keys are `name` for instance methods and `self.name` for singletons, so a
    # class method never answers for its instance namesake.
    def forwarded_block_requirements(source_code)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      sites = Hash.new { |hash, key| hash[key] = [] }
      each_forwarded_block(typing) do |send_node, method_key|
        block = required_callee_block(typing, send_node)
        sites[method_key] << block if block
      end

      # Any site that requires a block makes the method require one — calling it
      # without one would reach that call. The parameters only survive while the
      # sites agree; past that, `nil` widens them back to `*untyped`.
      sites.transform_values do |found|
        agreed = found.uniq
        { required: true, params: agreed.size == 1 && agreed.first != :unknown ? agreed.first : nil }
      end
    end

		private

		# Yields `[send_node, method_key]` for every call that receives a
    # `&block_param` — the method's own block on its way out. `&:symbol` is a
    # proc literal built on the spot, not this method's block, so it is not a
    # forward and never reaches the callee lookup.
    def each_forwarded_block(typing, &block)
      walk_forwarded_blocks(typing.source.node, nil, false, &block)
    end

    def walk_forwarded_blocks(node, method_key, singleton, &block)
      return unless node.is_a?(Parser::AST::Node)

      case node.type
      when :def then method_key = singleton ? "self.#{node.children[0]}" : node.children[0].to_s
      when :defs then method_key = "self.#{node.children[1]}"
      when :sclass then singleton = true
      when :send, :csend
        forwarded = node.children.any? do |child|
          child.is_a?(Parser::AST::Node) && child.type == :block_pass &&
            child.children[0]&.type == :lvar
        end
        block.call(node, method_key) if forwarded && method_key
      end

      node.children.each { |child| walk_forwarded_blocks(child, method_key, singleton, &block) }
    end

    # The block the callee declares, as `[param types]`, or `:unknown` when it
    # requires one whose shape we can't spell. `nil` when it requires none —
    # including when the receiver is untyped, where there is no callee to ask.
    #
    # Every declaration has to require it: a union receiver whose halves
    # disagree cannot force a block on this method.
    def required_callee_block(typing, send_node)
      call = typing.call_of(node: send_node)
      decls = call.respond_to?(:method_decls) ? call.method_decls.to_a : []
      return nil if decls.empty?
      return nil unless decls.all? { |decl| decl.method_type.block&.required }

      shapes = decls.map { |decl| callee_block_params(decl.method_type.block) }.uniq
      shapes.size == 1 ? shapes.first : :unknown
    rescue StandardError
      nil
    end

    # Only a plain list of required positionals is transcribable — an optional
    # or rest parameter in the callee's block has no place in the caller's
    # `(untyped, untyped)` shape, so it widens instead of guessing.
    def callee_block_params(block)
      function = block.type
      return :unknown unless function.respond_to?(:required_positionals)
      return :unknown unless function.optional_positionals.empty? && function.rest_positionals.nil? &&
        function.trailing_positionals.empty? && function.required_keywords.empty?

      function.required_positionals.map { |param| RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(param.type) }
    end
  end
end
