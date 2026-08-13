# frozen_string_literal: true

module RbsInfer::Inference
  # The block half of every method signature in a file, filled in after the fact.
  #
  # `ClassMemberCollector` emits it as a placeholder — `?{ (*untyped) -> untyped }` —
  # because the collector is structural and each of the four questions here needs
  # something it does not have: the CHECKER (what the body hands the block, what
  # binding a callee imposes, which overload a possibly-nil proc selects) or the
  # CALL SITES (what the blocks passed in actually return). What the collector can
  # settle it already did, and it recorded the rest on the member —
  # `block_arg_positions`, `block_open_forward`, `block_stored_forward` — for this
  # object to answer.
  #
  # They live together because they are one rewrite of one clause, in an order
  # that matters and that nothing outside needs to know:
  #
  #   (params) [self: T] -> return
  #    ↑        ↑           ↑
  #    #148     #208        #155      …and #149 decides the `?` in front of it.
  #
  # Parameters first, since `replace_block_param_types` only rewrites a list that
  # is still entirely `untyped`; then the `?`/shape from the callee, which matches
  # on the untouched-forward spelling; then the binding, which inserts between the
  # list and the arrow; and the return last, so it applies whatever the list ended
  # up being. Presented to the Analyzer as one step, `apply`.
  class BlockSignatureResolver
    # Members whose block return is still open, which the Analyzer needs BEFORE any
    # of this runs: they are the methods whose call sites it has to collect blocks
    # from in the first place.
    #
    # `to_s` because a member's signature is filled in by a later pass for some
    # kinds — this runs over every member the collector produced, not only the ones
    # with a method type.
    def self.untyped_block_return?(member)
      [:method, :class_method].include?(member.kind) && member.signature.to_s.include?("-> untyped }")
    end

    # `parsed_target` may be nil (a consumer that never parsed a target file); the
    # bridge answers every question here, so both are required. The block-return
    # target is normally the same parsed file. A contextual source relocation
    # supplies its pre-relocation form there because that is where the call-site
    # block still exists.
    def initialize(parsed_target:, parsed_block_return_target:, steep_bridge:)
      @parsed_target = parsed_target
      @parsed_block_return_target = parsed_block_return_target
      @steep_bridge = steep_bridge
    end

    # Rewrites the block clause of every member that has one, in place.
    #
    # `caller_returns` is what the blocks passed at the call sites returned,
    # collected by the Analyzer's caller sweep — `{ "with_token" => ["String"] }`,
    # or nil when that sweep never ran. Required rather than defaulted: a caller
    # that forgets it silently loses the only evidence a block's RETURN has
    # (docs/engineering/required-threaded-deps.md).
    def apply(members, caller_returns:)
      return if @parsed_target.nil?

      resolve_param_types(members)
      resolve_forwarded_requirements(members)
      resolve_stored_self_types(members)
      resolve_return_types(members, caller_returns)
    end

    private

    # A block's parameters are whatever the method PASSES to it, so the sites
    # that use the block are the evidence — and Steep has already typed those
    # expressions while checking the file. `authenticate` calls
    # `login_procedure.call(token, options)`, and asking about those two
    # positions answers `String` and `ActiveSupport::HashWithIndifferentAccess?`
    # for a block signature that was `{ (untyped, untyped) -> untyped }`.
    #
    # Positions come from the collector (structural, no bridge there); the types
    # come from here, the same division as constant defaults in the Analyzer.
    def resolve_param_types(members)
      selected = members.select do |m|
        [:method, :class_method].include?(m.kind) && m.block_arg_positions && !m.block_arg_positions.empty?
      end
      return if selected.empty?

      expression_types = @steep_bridge.all_expression_types(@parsed_target.source)
      return if expression_types.empty?

      selected.each do |member|
        types = member.block_arg_positions.map { |positions| param_type(positions, expression_types) }
        member.signature = RbsInfer::Signatures::RbsParserUtil.replace_block_param_types(member.signature, types)
      end
    end

    # One block parameter, across every site that uses the block: a method that
    # yields an Integer in one branch and a String in another gives its block a
    # union, exactly as the sites say.
    def param_type(positions, expression_types)
      keys = positions.map { |position| RbsInfer::Signatures::SteepBridge.expression_key(*position) }
      types = keys.filter_map { |key| expression_types[key] }.uniq
      return nil if types.empty?

      RbsInfer::Inference::TypeMerger.union_types(types)
    end

    # A method that forwards its block cannot say on its own whether one is
    # needed: `items.each(&block)` runs fine without it, `Token.authenticate`
    # does not. The callee decides, and the checker is what knows the callee —
    # including which of its overloads a possibly-nil proc selects.
    #
    # Only members the collector left open are touched: no call of their own, no
    # guard, nothing but the forward (`?{ (*untyped) -> untyped }`).
    def resolve_forwarded_requirements(members)
      selected = members.select { |m| [:method, :class_method].include?(m.kind) && m.block_open_forward }
      return if selected.empty?

      requirements = @steep_bridge.forwarded_block_requirements(@parsed_target.source)
      return if requirements.empty?

      selected.each do |member|
        requirement = requirements[method_key(member)]
        next unless requirement

        member.signature = RbsInfer::Signatures::RbsParserUtil.require_block(member.signature, requirement[:params])
      end
    end

    # A block kept in an ivar is replayed later, and the replay decides what `self`
    # is inside it — `base.class_eval(&@included_block)` runs the block against the
    # includer. That binding belongs in the signature: a caller writing
    # `included do … end` is writing a body against that `self`, and without it the
    # stored proc cannot be handed to `class_eval` at all (felixefelip/rbs_infer#208).
    #
    # Only members the collector left stored, and only the binding — see
    # `RbsParserUtil.bind_block_self` for what is deliberately not taken.
    def resolve_stored_self_types(members)
      selected = members.select { |m| [:method, :class_method].include?(m.kind) && m.block_stored_forward }
      return if selected.empty?

      bindings = @steep_bridge.stored_block_self_types(@parsed_target.source)
      return if bindings.empty?

      selected.each do |member|
        binding = bindings[method_key(member)]
        next unless binding

        member.signature = RbsInfer::Signatures::RbsParserUtil.bind_block_self(member.signature, binding)
      end
    end

    # A block's RETURN is the one half of its type the method cannot answer: it
    # receives that value rather than producing it, and a method that passes it
    # through (`block.call(token)`, `yield`) constrains it not at all. So the
    # evidence is the blocks the call sites pass — the same contract every
    # inferred parameter type already has, and unioned the same way.
    #
    # Sites that Steep cannot type are skipped rather than counted as `untyped`:
    # unioning one in would erase the answer the others gave.
    def resolve_return_types(members, caller_returns)
      selected = members.select { |m| self.class.untyped_block_return?(m) }
      return if selected.empty?

      returns = collect_returns(selected.map(&:name).to_set, caller_returns)
      return if returns.empty?

      selected.each do |member|
        observed = returns[member.name]
        next if observed.nil? || observed.empty?

        member.signature = RbsInfer::Signatures::RbsParserUtil.replace_block_return_type(
          member.signature, RbsInfer::Inference::TypeMerger.union_types(observed)
        )
      end
    end

    # Call sites in the target's own file plus every caller file. A receiverless
    # call here is a self-send, so the target's file needs no receiver check; the
    # caller files resolve theirs through `NewCallCollector`, which already knows
    # how (#131).
    def collect_returns(method_names, caller_returns)
      evidence_target = @parsed_block_return_target || @parsed_target
      collector = RbsInfer::Inference::BlockReturnCollector.new(
        methods: method_names,
        expression_types: @steep_bridge.all_expression_types(evidence_target.source)
      )
      evidence_target.tree.accept(collector)

      returns = collector.returns
      caller_returns&.each do |name, types|
        (returns[name] ||= []).concat(types)
      end
      propagate_along_forwards(returns, collector.forwards)
      returns
    end

    # A forwarded block carries the evidence one frame down
    # (felixefelip/rbs_infer#158):
    #
    #   def with_token(&block)
    #     fetch_token(&block) || deny
    #   end
    #
    # `fetch_token` has no call site with a block of its own — only this forward —
    # so it had nothing to go on. But every block that reaches it through this edge
    # is a block that reached `with_token`, whose answer the call sites already
    # gave. So the forwarder's evidence is the callee's.
    #
    # It is the mirror of felixefelip/rbs_infer#149, which walks the same edge the
    # other way: whether a block is REQUIRED is a demand the callee makes, while
    # what it RETURNS is evidence the caller supplies.
    #
    # A fixpoint because a chain is arbitrarily deep and the members come in no
    # order; it terminates because the lists only grow and a type is added once.
    def propagate_along_forwards(returns, forwards)
      return if forwards.empty?

      loop do
        changed = false

        forwards.each do |forwarder, callees|
          observed = returns[forwarder]
          next if observed.nil? || observed.empty?

          callees.each do |callee|
            inherited = (returns[callee] ||= [])
            observed.each do |type|
              next if inherited.include?(type)

              inherited << type
              changed = true
            end
          end
        end

        break unless changed
      end
    end

    # How the bridge keys its answers: `name`, and `self.name` for a singleton, so
    # a class method never answers for its instance namesake.
    def method_key(member)
      member.kind == :class_method ? "self.#{member.name}" : member.name
    end
  end
end
