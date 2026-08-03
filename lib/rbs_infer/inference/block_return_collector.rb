module RbsInfer::Inference
  # What the blocks passed at CALL SITES return, per method
  # (felixefelip/rbs_infer#155).
  #
  # A block type has two halves with opposite origins. The parameters are what
  # the method HANDS to the block, so its own body answers them (#148). The
  # return is what the method RECEIVES BACK, and a method that merely passes it
  # through — `block.call(token)`, `yield` — constrains it not at all. Its own
  # body has nothing to say.
  #
  # So the evidence is the callers: whatever blocks are actually passed. That is
  # the same contract every parameter type in this project already has — a
  # description of how the code IS used, not of what the method would tolerate —
  # and unioning across sites is the same answer given there.
  #
  # It is an approximation of a genuinely generic method (`[T] () { () -> T } ->
  # T?`), and it degrades the way a union should: adding a caller widens the
  # type rather than deleting it. Where a helper turns out to be truly
  # polymorphic, a two-member union in this position is the signal.
  class BlockReturnCollector < Prism::Visitor
    # `methods` — names whose signature carries a block. `expression_types` —
    # Steep's types for this source, keyed `"line:column"`. `receiver_check` — a
    # callable answering whether a call's receiver is the target; omit it for
    # the target's own file, where a receiverless call is a self-send.
    def initialize(methods:, expression_types:, receiver_check: nil)
      @methods = methods
      @expression_types = expression_types
      @receiver_check = receiver_check
      @returns = Hash.new { |hash, key| hash[key] = [] }
      @forwards = Hash.new { |hash, key| hash[key] = [] }
      super()
    end

    # `{ "with_token" => ["Example18::User?"] }` — one entry per call site.
    attr_reader :returns

    # `{ "with_token" => ["fetch_token"] }` — who hands their own block on to
    # whom. A forwarded block is not evidence by itself, but every block that
    # reaches the callee through this edge is one that reached the forwarder, so
    # the forwarder's answer is the callee's too. The caller resolves that, since
    # it needs a fixpoint over the whole set (felixefelip/rbs_infer#158).
    attr_reader :forwards

    def visit_def_node(node)
      previous_method, previous_block = @current_method, @current_block_param
      @current_method = node.name.to_s
      @current_block_param = node.parameters&.block&.name&.to_s
      super
    ensure
      @current_method, @current_block_param = previous_method, previous_block
    end

    def visit_call_node(node)
      if @methods.include?(node.name.to_s)
        case node.block
        when Prism::BlockNode then collect(node)
        when Prism::BlockArgumentNode then collect_forward(node)
        end
      end
      super
    end

    private

    def collect(node)
      return unless receiver_matches?(node)

      type = block_return_type(node.block)
      @returns[node.name.to_s] << type if type
    end

    # `fetch_token(&block)` inside `def with_token(&block)`. Only the enclosing
    # method's OWN block counts: `other(&:upcase)` or `other(&some_proc)` says
    # nothing about what reached this method.
    def collect_forward(node)
      return unless @current_method && receiver_matches?(node)
      return unless forwards_own_block?(node.block)

      @forwards[@current_method] << node.name.to_s
    end

    def forwards_own_block?(block_argument)
      expression = block_argument.expression
      @current_block_param && expression.is_a?(Prism::LocalVariableReadNode) &&
        expression.name.to_s == @current_block_param
    end

    def receiver_matches?(node)
      return node.receiver.nil? unless @receiver_check

      @receiver_check.call(node)
    end

    def block_return_type(block)
      self.class.block_return_type(block, @expression_types)
    end

    # The value of the block's last statement — read from the checker rather
    # than guessed, so a block ending in `if user = lookup(token) …` answers
    # with the nilable the `if` really produces.
    #
    # Exposed on the class because the cross-file path asks the same question
    # from `NewCallCollector`, which resolves receivers and so does the walking
    # itself (#131).
    def self.block_return_type(block, expression_types)
      body = block.body or return nil
      last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
      return nil unless last

      expression_types[RbsInfer::Signatures::SteepBridge.prism_expression_key(last.location)]
    end
  end
end
