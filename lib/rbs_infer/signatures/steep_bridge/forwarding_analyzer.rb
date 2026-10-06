class RbsInfer::Signatures::SteepBridge
  class ForwardingAnalyzer
    def initialize(steep_bridge:)
      @steep_bridge = steep_bridge
    end

    # Methods whose parameter list is `...`, mapped to the one method they hand
    # it to:
    #
    #   { "email" => { kind: :instance, class_name: "User", method_name: "email" } }
    #
    # for
    #
    #   def email(...)
    #     _ = user
    #     _.email(...)
    #   end
    #
    # which is what `delegate :email, to: :user` writes. `...` accepts whatever
    # the call it forwards to accepts, so that call's DECLARATION is the
    # method's parameter list — and which method the call resolves to is the
    # checker's to say.
    #
    # Only where every forwarding call in the body resolves to the same one
    # method: two different callees accept two different lists, and nothing
    # here picks between them. Keys are `name`, or `self.name` for singletons.
    #
    # Only a call the checker resolved has a method to read: a receiver that
    # may be nil is rejected whole, and the method keeps what `...` accepts in
    # general until a caller establishes the receiver — the precondition the
    # checker infers from that rejection (`not_nil self.user`), enforced at
    # the call sites, narrows the body and resolves the call. Nothing here
    # reads past what the checker says.
    def forwarded_call_targets(source_code)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      targets = {}
      each_forwarding_def(typing.source.node) do |def_node, method_key|
        callees = forwarding_calls(def_node).map { |send_node| callee(typing, send_node) }
        next if callees.empty? || callees.any?(&:nil?) || callees.uniq.size != 1

        targets[method_key] = callees.first
      end
      targets
    end

    private

    def each_forwarding_def(node, &block)
      return unless node.is_a?(Parser::AST::Node)

      if (node.type == :def || node.type == :defs) && forwards_only?(node)
        name = node.type == :defs ? node.children[1] : node.children[0]
        yield node, node.type == :defs ? "self.#{name}" : name.to_s
      end

      node.children.each { |child| each_forwarding_def(child, &block) }
    end

    # `(...)` and nothing else.
    def forwards_only?(def_node)
      args = def_node.type == :defs ? def_node.children[2] : def_node.children[1]
      args.is_a?(Parser::AST::Node) && args.children.size == 1 && args.children[0].type == :forward_arg
    end

    # The calls in the body that pass `...` on, stopping at a body of its own.
    def forwarding_calls(def_node)
      body = def_node.type == :defs ? def_node.children[3] : def_node.children[2]
      calls = []
      walk(body) do |node|
        next unless node.type == :send || node.type == :csend

        calls << node if node.children.drop(2).any? { |argument| argument.is_a?(Parser::AST::Node) && argument.type == :forwarded_args }
      end
      calls
    end

    def walk(node, &block)
      return unless node.is_a?(Parser::AST::Node)
      return if %i[def defs class module sclass].include?(node.type)

      yield node
      node.children.each { |child| walk(child, &block) }
    end

    # The one method a call resolved to, or nil when it resolved to none, or
    # to several (a union receiver whose halves declare it apart).
    def callee(typing, send_node)
      call = typing.call_of(node: send_node)
      decls = call.respond_to?(:method_decls) ? call.method_decls.to_a : []
      names = decls.map(&:method_name).uniq
      return nil unless names.size == 1

      name = names.first
      kind = name.is_a?(Steep::SingletonMethodName) ? :singleton : :instance
      { kind: kind, class_name: name.type_name.to_s.delete_prefix("::"), method_name: name.method_name.to_s }
    rescue Steep::Typing::UnknownNodeError
      nil
    end
  end
end
