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
    # Where the checker resolved the call, it also typed the body, so the
    # method's return is the one already resolved for it. Where it did not —
    # a receiver that may be nil, which the checker rejects whole — `returns:`
    # says whether the method's VALUE is that call: every way the body can end
    # is the call, a `raise`, or (with `nilable:`) nothing. Then the method
    # returns what the call returns, as surely as it accepts what the call
    # accepts:
    #
    #   def name(...)
    #     _ = tag              # Tag?
    #     if !_.nil? || nil.respond_to?(:name)
    #       _.name(...)        # the call…
    #     end                  # …or nil
    #   end
    def forwarded_call_targets(source_code)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      targets = {}
      each_forwarding_def(typing.source.node) do |def_node, method_key|
        calls = forwarding_calls(def_node)
        callees = calls.map { |send_node| callee(typing, send_node) }
        next if callees.empty? || callees.any?(&:nil?) || callees.map(&:first).uniq.size != 1

        target, = callees.first
        if callees.all? { |_, resolved| resolved }
          targets[method_key] = target.merge(returns: false, nilable: false)
        else
          ends = tails(body_of(def_node))
          returns = ends.all? { |tail| tail == :nil || calls.any? { |call| call.equal?(tail) } }
          targets[method_key] = target.merge(returns: returns, nilable: returns && ends.include?(:nil))
        end
      end
      targets
    end

    private

    def body_of(def_node)
      def_node.type == :defs ? def_node.children[3] : def_node.children[2]
    end

    # Where a body's value comes from: the node it ends on, through `begin`,
    # the arms of an `if` and the clauses of a `rescue`. `:nil` for an end with
    # no value; a `raise` ends nothing.
    def tails(node)
      return [:nil] unless node.is_a?(Parser::AST::Node)

      case node.type
      when :begin, :kwbegin
        tails(node.children.last)
      when :if
        tails(node.children[1]) + tails(node.children[2])
      when :rescue
        body, *clauses, else_clause = node.children
        (else_clause ? tails(else_clause) : tails(body)) +
          clauses.flat_map { |clause| tails(clause.children[2]) }
      when :ensure
        tails(node.children[0])
      when :nil
        [:nil]
      else
        raises?(node) ? [] : [node]
      end
    end

    def raises?(node)
      return false unless node.type == :send && node.children[1] == :raise

      receiver = node.children[0]
      receiver.nil? || (receiver.type == :const && receiver.children[1] == :Kernel)
    end

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

    # `[method, resolved]`: the one method a call reaches, and whether the
    # checker resolved the call itself. nil when it reaches none, or several
    # (a union receiver whose halves declare it apart).
    def callee(typing, send_node)
      call = typing.call_of(node: send_node)
      decls = call.respond_to?(:method_decls) ? call.method_decls.to_a : []
      return receiver_callee(typing, send_node)&.then { |target| [target, false] } if decls.empty?

      names = decls.map(&:method_name).uniq
      return nil unless names.size == 1

      name = names.first
      kind = name.is_a?(Steep::SingletonMethodName) ? :singleton : :instance
      [{ kind: kind, class_name: name.type_name.to_s.delete_prefix("::"), method_name: name.method_name.to_s }, true]
    rescue Steep::Typing::UnknownNodeError
      nil
    end

    # When the call itself names no method, the RECEIVER may still say which
    # one it is — a receiver that may be nil, which the checker rejects:
    #
    #   _ = user            # User?
    #   _.email(...)        # a NoMethodError for nil
    #
    # nil is taken out: the call that passes `...` on is the one made when the
    # receiver is NOT nil — nil raises instead, which is what the
    # `rescue NoMethodError` around it is for. What is left has to be exactly
    # one class.
    def receiver_callee(typing, send_node)
      receiver = send_node.children[0] or return nil
      type = typing.type_of(node: receiver)
      named = type
      if type.is_a?(Steep::AST::Types::Union)
        rest = type.types.reject { |member| member.is_a?(Steep::AST::Types::Nil) }
        return nil unless rest.size == 1

        named = rest.first
      end

      kind =
        case named
        when Steep::AST::Types::Name::Instance then :instance
        when Steep::AST::Types::Name::Singleton then :singleton
        else return nil
        end

      { kind: kind, class_name: named.name.to_s.delete_prefix("::"), method_name: send_node.children[1].to_s }
    rescue Steep::Typing::UnknownNodeError
      nil
    end
  end
end
