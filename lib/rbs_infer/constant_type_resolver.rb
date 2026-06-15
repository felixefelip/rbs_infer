module RbsInfer
  # Resolves the RBS type of a class/module constant's RHS
  # (felixefelip/rbs_infer#37). The inference pieces already exist; this
  # composes them with the right precedence so a constant resolves as
  # precisely in a single pass as it eventually would after convergence.
  #
  # Precedence, highest first:
  #
  # 1. Prism constructor inference — expressions whose type hinges on a
  #    `new` call against a class whose RBS doesn't exist yet. This is the
  #    one thing Steep can't do single-pass (it types `new` of an unknown
  #    class as `Object`). It encodes the generation-time fact that
  #    `new`/`self.new` build the class being generated and `Foo.new`
  #    builds `Foo`, threaded through the collection-builder idiom so
  #    `{...}.collect { new(...) }.freeze` → `Array[<class>]`. Multi-pass
  #    Steep agrees here once the RBS exists, so leading with Prism keeps
  #    single/multi-pass output identical.
  # 2. Steep — the oracle for everything else: precise array/hash element
  #    types, comparison/arithmetic chains, and `new`-bearing chains once
  #    the class's RBS exists (later passes).
  # 3. `NodeTypeInferrer` leaves — literals, constants, `Klass.new`, records
  #    — as the fallback when Steep is unavailable or returned nothing.
  # 4. `untyped` — nothing static could decide it.
  class ConstantTypeResolver
    include NodeTypeInferrer

    # Methods that return their receiver unchanged (`self`), so the chain's
    # type is the receiver's type. Lets a trailing `.freeze` (the common
    # "frozen constant" idiom) pass the element type through.
    PASSTHROUGH_METHODS = %i[freeze dup clone tap itself].freeze

    # Block methods whose result is `Array[<block body type>]`. Same set
    # the SteepBridge corrects generics for (`BLOCK_GENERIC_METHODS`), plus
    # `flat_map`; here it lets the block body's constructor type flow out.
    ARRAY_BLOCK_METHODS = %i[map collect flat_map].freeze

    def initialize(target_class:)
      @target_class = target_class
    end

    # @param node [Prism::Node, nil] the constant's RHS
    # @param steep_type [String, nil] Steep's type for this constant
    # @return [String] an RBS type (never nil; falls back to "untyped")
    def resolve(node, steep_type: nil)
      return "untyped" if node.nil?

      prism_constructor_type(node) ||
        usable_steep_type(steep_type) ||
        infer_node_type(node, context_class: @target_class) ||
        "untyped"
    end

    private

    def usable_steep_type(type)
      return nil if type.nil? || %w[untyped bot void nil].include?(type)

      type
    end

    # Type of an expression whose result is a freshly-built instance, or nil
    # when the node isn't constructor-shaped (so the caller falls through to
    # Steep / leaf inference).
    def prism_constructor_type(node)
      return nil unless node.is_a?(Prism::CallNode)

      if node.name == :new
        new_call_class(node)
      elsif node.receiver
        chain_constructor_type(node)
      end
    end

    # `new` / `self.new` → the class being generated; `Foo.new` → `Foo`.
    # A computed receiver (`self.class.new`, `klass.new`) yields nil.
    def new_call_class(call)
      if call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)
        @target_class
      else
        RbsInfer::Analyzer.extract_constant_path(call.receiver)
      end
    end

    # Walk a receiver chain, propagating the constructor type: `freeze` &
    # friends pass the receiver's type through; `map`/`collect` wrap the
    # block body's constructor type in `Array[...]`. Returns nil for any
    # other shape so Steep gets the final say.
    def chain_constructor_type(call)
      if PASSTHROUGH_METHODS.include?(call.name)
        prism_constructor_type(call.receiver)
      elsif ARRAY_BLOCK_METHODS.include?(call.name) && call.block.is_a?(Prism::BlockNode)
        element = block_result_constructor_type(call.block)
        element && "Array[#{element}]"
      end
    end

    def block_result_constructor_type(block)
      body = block.body
      return nil unless body

      last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
      last && prism_constructor_type(last)
    end
  end
end
