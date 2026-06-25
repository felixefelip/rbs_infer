module RbsInfer::Inference
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
    include RbsInfer::AST::NodeTypeInferrer

    def initialize(target_class:)
      @target_class = target_class
      @constructor_inferrer = RbsInfer::AST::ConstructorTypeInferrer.new(target_class: target_class)
    end

    # @param node [Prism::Node, nil] the constant's RHS
    # @param steep_type [String, nil] Steep's type for this constant, or nil
    #   when Steep had none — required (not defaulted) so a caller that has a
    #   Steep type can't silently drop it; pass `nil` explicitly to opt out.
    # @return [String] an RBS type (never nil; falls back to "untyped")
    def resolve(node, steep_type:)
      return "untyped" if node.nil?

      @constructor_inferrer.infer(node) ||
        usable_steep_type(steep_type) ||
        infer_node_type(node, context_class: @target_class) ||
        "untyped"
    end

    private

    def usable_steep_type(type)
      return nil if type.nil? || %w[untyped bot void nil].include?(type)

      type
    end
  end
end
