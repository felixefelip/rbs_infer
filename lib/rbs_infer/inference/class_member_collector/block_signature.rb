class RbsInfer::Inference::ClassMemberCollector < Prism::Visitor
  # The block half of a method signature — in RBS it sits AFTER the closing
  # paren, and it is decided by different evidence than everything inside them:
  # not the parameter list, but what the body DOES with the block.
  #
  # A block is REQUIRED when the body cannot run without one: it `yield`s, or it
  # calls the block parameter, and it never asks whether a block is there. A
  # guard — `if block`, `block_given?`, `block&.call`, `block.nil?` — is
  # precisely what makes `?{ … }` right, so its presence is what keeps the `?`.
  #
  # Forwarding (`foo(&block)`) is NOT proof. Passing a nil block along is legal
  # Ruby, and a helper that hands its block to `tag.section` or `items.each` is
  # called without one all the time — treating the forward as a requirement
  # declares those mandatory, which is simply false.
  #
  # It leaves a gap: forwarding into a callee that DOES require a block should
  # make the forwarder require one too. That is a transitive question, needing a
  # view of the callee this object does not have. Recorded rather than guessed
  # at.
  #
  # The block's PARAMETERS come from the same places: `yield x, y` and
  # `block.call(x, y)` say how many the block takes, and — once someone types
  # those expressions — what they are. Only the count is settled here; the
  # types are looked up in the Analyzer, which owns the checker
  # (felixefelip/rbs_infer#148).
  #
  # Declaring every block optional made `block.call` a call on `Proc | nil`, so
  # the checker refused the one line such a method exists for; and a method that
  # only `yield`s declared no block at all, which is how a caller passing one got
  # `No block given for `yield`` (felixefelip/rbs_infer#147).
  class BlockSignature
    # `params` may be nil (a method with no parameter list can still `yield`).
    def initialize(params, body: nil)
      @params = params
      @body = body
    end

    # The RBS fragment, or nil when the method takes no block at all.
    def call
      return nil unless block_param_name || yields?

      "#{"?" unless required?}{ (#{block_params}) -> untyped }"
    end

    # Where the values the body hands to the block sit in the source, one entry
    # per block parameter: `[[[line, column], …], …]`, columns in CHARACTERS so
    # a Parser-based lookup lines up (felixefelip/rbs_infer#142).
    #
    # Only the positions: the TYPES there are the checker's answer, and the
    # checker belongs to the Analyzer. This object is structural, like the rest
    # of the collector — same split as `constant_default_params`.
    def arg_positions
      return [] unless arity

      Array.new(arity) { |slot| use_sites.filter_map { |args| position_of(args[slot]) } }
    end

    private

    def required?
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

    # The arity the body uses the block with, as `untyped` params — the types
    # are filled in later, from the same use sites (see `arg_positions`).
    #
    # Fixed at one before, which nothing checked while every block was optional
    # — a required block IS checked, and `login_procedure.call(token, options)`
    # against a one-parameter block is `Unexpected positional argument`. An
    # optional block is just as checkable at the call site, so it reads the body
    # too rather than keeping the old guess.
    def block_params
      arity ? Array.new(arity, "untyped").join(", ") : "*untyped"
    end

    # `nil` for both kinds of not-knowing: use sites that disagree, and a body
    # that only FORWARDS the block, which says nothing about its arity.
    # Defaulting those to one parameter made the forward itself a mismatch
    # against a callee that takes two — `*untyped` is the honest answer.
    def arity
      arities = use_sites.map(&:size).uniq

      arities.first if arities.size == 1
    end

    # Every place the body hands values to the block, as its argument nodes.
    # `block&.call` counts here though it does not count as *requiring* a block:
    # a guarded call still shows what the block is called WITH.
    def use_sites
      @use_sites ||= [].tap do |sites|
        walk_nodes do |node|
          sites << arguments_of(node) if node.is_a?(Prism::YieldNode)
          next unless node.is_a?(Prism::CallNode) && node.name == :call && block_param_name
          next unless reads_block?(node.receiver, block_param_name)

          sites << arguments_of(node)
        end
      end
    end

    def arguments_of(node)
      node.arguments&.arguments || []
    end

    def position_of(node)
      [node.location.start_line, node.location.start_character_column] if node
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
