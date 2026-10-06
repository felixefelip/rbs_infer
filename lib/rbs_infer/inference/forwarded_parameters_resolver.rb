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
        member.signature = forward_lists(member, target)
      end
    end

    private

    # The parameter lists alone, under the return the earlier passes resolved.
    def forward_lists(member, target)
      kind, class_name = callee_class(target)
      return member.signature unless kind

      lists = @method_type_resolver.resolve_method_parameters(kind, class_name, target[:method_name])
      return member.signature if lists.empty? || lists.any? { |list| list.match?(CONTEXTUAL) }

      RbsInfer::Signatures::RbsParserUtil.forward_parameters(member.signature, lists)
    end

    # `[kind, class]` of the method the call reaches. A call the checker
    # rejected names its receiver's type instead, and reaches what a call on
    # that receiver reaches by the rule every nilable call follows: `User?`
    # reaches `User` where nil does not have the method.
    def callee_class(target)
      return [target[:kind], target[:class_name]] unless target[:receiver_type]

      receiver = @method_type_resolver.optimistic_receiver(target[:receiver_type], target[:method_name]) or return nil
      singleton = receiver[/\Asingleton\((.+)\)\z/, 1]
      singleton ? [:singleton, singleton] : [:instance, receiver]
    end

    def method_key(member)
      member.kind == :class_method ? "self.#{member.name}" : member.name
    end
  end
end
