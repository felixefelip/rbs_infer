module RbsInfer::Inference
  # The own-method return types of the class currently being generated, for
  # resolving calls whose receiver IS that class.
  #
  # NOTE: this is NOT Steep's self-type context (`Steep::TypeInference::Context#self_type`,
  # the *type of `self`*). It carries the opposite, generation-time half: the
  # class's partially-inferred method *return types*, which stand in for the
  # RBS method table that doesn't exist on disk yet. While generating a class's
  # RBS, `MethodTypeResolver` can't resolve a method called on a receiver whose
  # type IS the class being generated (`new.run`, `self.new.build`,
  # `TwinNames.run`) — it returns nil. The two return-type maps already built
  # for the class are the local source of truth for exactly those calls: the
  # in-flight analog of the RBS the resolver would consult for an external
  # class.
  #
  # The maps are kept split by kind (`instance_types` for `:method`,
  # `class_types` for `:class_method`) so a call resolves against the surface
  # matching the RECEIVER's kind, never the called method's name. That is what
  # keeps the local fallback from reintroducing the instance/class
  # return-type leak of felixefelip/rbs_infer#33: #34 separated the maps; this
  # context threads both so `new.<instance method>` resolves in a single pass
  # (felixefelip/rbs_infer#35) without crossing the boundary.
  class SelfReturnTypeContext
    attr_reader :target_class, :instance_types, :class_types, :own_kind

    # @param target_class [String, nil] the class being generated
    # @param instance_types [Hash] name → return type for its instance methods
    # @param class_types [Hash] name → return type for its singleton methods
    # @param own_kind [Symbol] kind (:method / :class_method) of the method
    #   whose body is being resolved — selects the map for receiverless /
    #   implicit-self calls, whose receiver IS the enclosing self.
    def initialize(target_class:, instance_types:, class_types:, own_kind:)
      @target_class = target_class
      @instance_types = instance_types
      @class_types = class_types
      @own_kind = own_kind
    end

    # Map for receiverless / implicit-self lookups (`foo`, `self.foo`): the
    # enclosing method's own kind.
    def own_types
      @own_kind == :class_method ? @class_types : @instance_types
    end

    # Map for an explicit receiver whose resolved type is `target_class`,
    # picked by whether the receiver denotes the class itself (a constant →
    # singleton methods) or an instance of it (`new`, a typed local → instance
    # methods).
    def self_types_for(receiver_kind)
      receiver_kind == :singleton ? @class_types : @instance_types
    end

    # Does `type` name the class being generated? Guards the local fallback so
    # it fires only for self-calls, never for an external receiver.
    def own_class?(type)
      !@target_class.nil? && type == @target_class
    end
  end
end
