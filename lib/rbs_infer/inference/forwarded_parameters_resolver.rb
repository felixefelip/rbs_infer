# frozen_string_literal: true

module RbsInfer::Inference
  # The parameter list of a method that takes `...`, filled in after the fact.
  #
  # `def email(...) = user.email(...)` accepts exactly what `User#email` does —
  # `...` is "the same arguments, passed on". The collector cannot say what that
  # is (it does not know where `user` points), so it emits what `...` accepts in
  # general, `(*untyped, **untyped) ?{ (*untyped) -> untyped }`, and marks the
  # member. Here the checker says which method the forwarding call resolves to,
  # and that method's declaration supplies the list: one overload per declared
  # overload, block included. The return the earlier passes resolved stays.
  #
  # This is how `delegate` gets its parameters now that nothing reads the macro:
  # ActiveSupport writes `def email(...)` for every target whose parameters it
  # does not reflect on, and the signature `delegate` used to copy by hand
  # (felixefelip/rbs_infer#294) comes from the same declaration, through the
  # call the generated body makes.
  #
  # A list that names `self`, `instance` or `class` is declined: those mean the
  # callee's class there, and something else here.
  class ForwardedParametersResolver
    CONTEXTUAL = /(?<![\w:])(self|instance|class)(?![\w?!])/

    # Both are required: the bridge says where each `...` goes, and the
    # resolver reads what is declared there.
    def initialize(parsed_target:, steep_bridge:, method_type_resolver:)
      @parsed_target = parsed_target
      @steep_bridge = steep_bridge
      @method_type_resolver = method_type_resolver
    end

    def apply(members)
      return if @parsed_target.nil?

      selected = members.select { |m| [:method, :class_method].include?(m.kind) && m.params_forward }
      return if selected.empty?

      targets = @steep_bridge.forwarded_call_targets(@parsed_target.source)
      return if targets.empty?

      selected.each do |member|
        target = targets[method_key(member)] or next
        member.signature = target[:returns] ? forward_overloads(member, target) : forward_lists(member, target)
      end
    end

    private

    # The parameter lists alone, under the return the earlier passes resolved.
    def forward_lists(member, target)
      lists = @method_type_resolver.resolve_method_parameters(target[:kind], target[:class_name], target[:method_name])
      return member.signature if lists.empty? || lists.any? { |list| list.match?(CONTEXTUAL) }

      RbsInfer::Signatures::RbsParserUtil.forward_parameters(member.signature, lists)
    end

    # Whole overloads, return included, where the body's value IS the call —
    # nilable where it can also end with none.
    def forward_overloads(member, target)
      overloads = @method_type_resolver.resolve_method_overloads(target[:kind], target[:class_name], target[:method_name])
      return forward_lists(member, target) if overloads.empty? || overloads.any? { |overload| overload.join(" ").match?(CONTEXTUAL) }

      rendered = overloads.map do |params, returned|
        returned = RbsInfer::Signatures::RbsParserUtil.nilablize(returned) if target[:nilable]
        [params, returned]
      end
      RbsInfer::Signatures::RbsParserUtil.forward_overloads(member.signature, rendered)
    end

    def method_key(member)
      member.kind == :class_method ? "self.#{member.name}" : member.name
    end
  end
end
