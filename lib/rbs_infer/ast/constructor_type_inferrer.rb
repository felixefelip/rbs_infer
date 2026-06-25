# frozen_string_literal: true

module RbsInfer::AST
  # Pure-AST inference of the instance type a constructor-shaped expression
  # builds, read off the Prism node alone (felixefelip/rbs_infer#37). No Steep,
  # no RBS, no cross-file resolution — just the syntactic shape, parameterized
  # by the name of the class being generated (`target_class`).
  #
  # Extracted from ConstantTypeResolver so the constructor reasoning lives in
  # the AST layer it belongs to; ConstantTypeResolver keeps only the inference
  # precedence (Prism constructor → Steep → leaf) that composes it. Modeled as
  # a small parameterized object (like the ast/ collectors that take
  # `target_class` in their initializer) so `target_class` is held once and the
  # node-walking helpers stay private.
  #
  # Recognized shapes:
  # - `new` / `self.new`            → the class being generated
  # - `Foo.new`                     → `Foo`
  # - `<ctor>.freeze` (& friends)   → the receiver's constructor type
  # - `{...}.map { <ctor> }`        → `Array[<ctor>]`
  class ConstructorTypeInferrer
    # Methods that return their receiver unchanged (`self`), so the chain's
    # type is the receiver's type. Lets a trailing `.freeze` (the common
    # "frozen constant" idiom) pass the element type through.
    PASSTHROUGH_METHODS = %i[freeze dup clone tap itself].freeze

    # Block methods whose result is `Array[<block body type>]`. Same set the
    # SteepBridge corrects generics for (`BLOCK_GENERIC_METHODS`), plus
    # `flat_map`; here it lets the block body's constructor type flow out.
    ARRAY_BLOCK_METHODS = %i[map collect flat_map].freeze

    # @param target_class [String, nil] the class being generated
    def initialize(target_class:)
      @target_class = target_class
    end

    # Type of an expression whose result is a freshly-built instance, or nil
    # when the node isn't constructor-shaped (so the caller can fall through to
    # Steep / leaf inference).
    #
    # @param node [Prism::Node, nil] the expression node
    # @return [String, nil] an RBS type, or nil when not constructor-shaped
    def infer(node)
      return nil unless node.is_a?(Prism::CallNode)

      if node.name == :new
        new_call_class(node)
      elsif node.receiver
        chain_constructor_type(node)
      end
    end

    private

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
    # friends pass the receiver's type through; `map`/`collect` wrap the block
    # body's constructor type in `Array[...]`. Returns nil for any other shape
    # so Steep gets the final say.
    def chain_constructor_type(call)
      if PASSTHROUGH_METHODS.include?(call.name)
        infer(call.receiver)
      elsif ARRAY_BLOCK_METHODS.include?(call.name) && call.block.is_a?(Prism::BlockNode)
        element = block_result_constructor_type(call.block)
        element && "Array[#{element}]"
      end
    end

    def block_result_constructor_type(block)
      body = block.body
      return nil unless body

      last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
      last && infer(last)
    end
  end
end
