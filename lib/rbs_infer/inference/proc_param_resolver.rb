# frozen_string_literal: true

module RbsInfer
  module Inference
    # The parameter list of a proc a method receives as an ordinary argument, from
    # the calls the body makes on it: `default_proc.call(self, key)` turns the
    # `^(*untyped) -> untyped` its call sites gave into `^(self, untyped) -> untyped`.
    #
    # Only a proc whose parameters the call sites left open is touched. A parameter
    # the call sites did not type as a proc may hold any object answering `call`.
    class ProcParamResolver
      OPEN_PROC = /\A(?<open>\(?)\^\(\*untyped\) -> untyped(?<close>\)?\??)\z/

      def initialize(parsed_target:, steep_bridge:, target_class:)
        @parsed_target = parsed_target
        @steep_bridge = steep_bridge
        @target_class = target_class
      end

      def apply(members, method_param_types)
        selected = members.select { |m| %i[method class_method].include?(m.kind) && m.proc_param_calls&.any? }
        return if selected.empty? || @parsed_target.nil?

        expression_types = @steep_bridge.all_expression_types(@parsed_target.source, file: @parsed_target.path)
        selected.each { |member| apply_to(member, method_param_types, expression_types) }
      end

      private

      def apply_to(member, method_param_types, expression_types)
        tables = MethodKey.tables(method_param_types, member.name,
                                  owner: MethodKey.qualify_owner(@target_class, member.owner), kind: member.kind)
        member.proc_param_calls.each do |name, slots|
          params = slots.map { |entries| slot_type(entries, expression_types) }
          tables.each { |table| table[name] = with_params(table[name], params) if table[name] }
        end
      end

      def with_params(type, params)
        match = OPEN_PROC.match(type) or return type

        "#{match[:open]}^(#{params.join(", ")}) -> untyped#{match[:close]}"
      end

      # Every call has to be typed: one the checker could not answer may have
      # passed anything.
      def slot_type(entries, expression_types)
        types = entries.map do |entry|
          entry == :self ? "self" : expression_types[RbsInfer::Signatures::SteepBridge.expression_key(*entry)]
        end
        return "untyped" if types.empty? || types.include?(nil)

        RbsInfer::Signatures::RbsParserUtil.unparenthesized(TypeUnion.of(types.uniq))
      end
    end
  end
end
