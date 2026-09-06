# frozen_string_literal: true

require "prism"
require_relative "node_reading"
require_relative "../../ast/constant_reference"

module RbsInfer::Project::StoredBlockReplayExpander
  # The DSL shapes a method body can be written in, each read off the body
  # alone: a block kept in a slot, a block replayed on a parameter, a block run
  # where it stands, a module handed to a hook, a call forwarded to another.
  #
  # One method per shape, and every one of them a function — a body and the
  # names it was handed go in, a tuple or nil comes out. What the shape MEANS
  # for this file (whose block it is, which class it lands on) is
  # `Collector`'s question, and needs the declarations, the providers and the
  # absorbed corpus that only `Collector` has. Keeping the two apart is what
  # lets the readings be checked against a source string with nothing else set
  # up (felixefelip/rbs_infer#303).
  #
  # Declining is a first-class answer here, and the shapes say so the same way
  # throughout: more than one candidate is an ambiguity this pass does not
  # guess about, so it answers nothing rather than pick.
  module ShapeReader
    include NodeReading
    extend self

    def stored_block_ivar(body, block_name)
      nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::InstanceVariableWriteNode)
        next unless node.value.is_a?(Prism::LocalVariableReadNode)
        next unless node.value.name.to_s == block_name

        node.name.to_s
      end.uniq.then { |ivars| ivars.first if ivars.size == 1 }
    end

    # `class_eval(&parameter.reader)` / `module_eval(&parameter.reader)`.
    # The receiver is deliberately limited to the method parameter: a replay
    # against arbitrary state needs a type/data-flow answer this source-only
    # pass does not have and must decline rather than guess.
    def replay_shape(body)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::CallNode)
        reader = dispatched(pass.expression)
        next unless (reader.arguments&.arguments || []).empty?
        next unless reader.receiver.is_a?(Prism::LocalVariableReadNode)

        next unless (own = own_receiver(call.receiver))

        [reader.receiver.name.to_s, reader.name.to_s, own == :singleton]
      end.uniq
      shapes.first if shapes.size == 1
    end

    # `<parameter>.class_eval(&@ivar)` — the target is the parameter and the
    # block is the method's own state. Same conservatism as `replay_shape` and
    # for the same reason, only about the other half: there the RECEIVER is
    # `self` and the parameter must be the one carrying the block; here the
    # parameter is the receiver and the block must come off `self`.
    #
    # `if @ivar` guards and `unless base.nil?` branches are irrelevant to the
    # shape — the whole body is scanned, exactly as `replay_shape` scans it.
    # They are NOT irrelevant to where the block lands, and that is a separate
    # question with a separate reader: see `deferral_shape`.
    def inward_replay_shape(body, parameters)
      shapes = nodes(body).filter_map { |node| inward_replay_at(node, parameters) }.uniq
      shapes.first if shapes.size == 1
    end

    # The one node above, read on its own so the branch-aware pass can ask the
    # same question of a node whose PATH it is holding.
    def inward_replay_at(node, parameters)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      return nil unless REPLAY_METHODS.include?(call.name)

      target, singleton = handed_receiver(call.receiver, parameters)
      return nil unless target

      pass = call.block
      return nil unless pass.is_a?(Prism::BlockArgumentNode)

      ivar = pass.expression
      return nil unless ivar.is_a?(Prism::InstanceVariableReadNode)

      [target, ivar.name.to_s, singleton]
    end

    # `<parameter>.instance_variable_set(:@x, …)`, as `[parameter, ivar]` — what
    # a DSL runs on the objects it is handed, and so what says which objects
    # hold `@x`.
    #
    # `DeferralReader` is what asks: the deferral says the DSL defers, and
    # this says WHOSE branch is taken, because the objects holding the slot
    # are the ones this method ran for. It is read here rather than there
    # because it needs no readers and runs during collection, before the
    # second lexical walk that finds them.
    def slot_init_shapes(body, parameters)
      nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)

        call = dispatched(node)
        next unless call.name == :instance_variable_set

        parameter = parameter_name(call.receiver, parameters)
        next unless parameter

        ivar = symbol_name((call.arguments&.arguments || []).first)
        [parameter, ivar] if ivar
      end.uniq
    end

    # `<parameter>.class_eval do … end` — the inward replay with the block
    # written in place rather than fetched from a slot. Same receiver rule as
    # `inward_replay_shape` and for the same reason; what differs is only where
    # the block comes from, so what it answers is the block itself.
    def literal_replay_shape(body, parameters)
      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        target, singleton = handed_receiver(call.receiver, parameters)
        next unless target
        block = call.block
        next unless block.is_a?(Prism::BlockNode)

        [call.name.to_s, block, singleton]
      end
      shapes.first if shapes.size == 1
    end

    # `<target>.class_eval(&block)` where `block` is the METHOD'S OWN parameter,
    # as `[name, dynamic?, singleton?]`.
    #
    # The mirror of `replay_shape`: there the receiver is the DSL's own `self`
    # and the block is fetched from the source object, here the block is the one
    # we were handed and the receiver is what may be somewhere else. So the
    # conservatism moves with it — what has to be decidable is the TARGET, and
    # `own_receiver` answers for the two spellings that name our own `self`
    # while `ConstantReference` answers for the two that name a constant.
    #
    # Anything else declines: a receiver that is a local, an ivar, or a method
    # call is an object this pass cannot name, and a block relocated onto the
    # wrong class is worse than one left where it was written.
    #
    # One shape per method, like the other replay readers. Two `class_eval`s of
    # one block onto two different targets is not something the source decides
    # for a caller — which of them a runtime dispatch reaches is the question
    # this pass declines rather than guesses at.
    def own_block_replay_shape(body, block_name)
      return nil unless block_name

      shapes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        next unless REPLAY_METHODS.include?(call.name)
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::LocalVariableReadNode)
        next unless pass.expression.name.to_s == block_name

        replayed_onto(call.receiver, body)
      end.uniq

      shapes.first if shapes.size == 1
    end

    # What such a replay runs ON, as `[name, dynamic?, singleton?]`, or nil for a
    # receiver this pass will not name. A nil NAME is an answer rather than a
    # refusal: it is the DSL's own `self`, whoever that turns out to be at the
    # call site.
    #
    # A LOCAL is read through to what the body puts in it. `ActiveSupport` writes
    # the module to a local before evaluating into it, and so does anyone who
    # needs the name twice — a local is where you put a value you are about to
    # use, not an object this pass cannot name (felixefelip/rbs_infer#268).
    def replayed_onto(receiver, body)
      case own_receiver(receiver)
      when :instance then [nil, false, nil, false]
      when :singleton then [nil, false, nil, true]
      else
        return nil unless receiver

        named = if receiver.is_a?(Prism::LocalVariableReadNode)
                  local_constant(receiver.name.to_s, body)
                else
                  RbsInfer::AST::ConstantReference.named(receiver)
                end
        [*named, false] if named
      end
    end

    # The constant a local holds, when the body says so plainly: EVERY way it is
    # filled names the same one.
    #
    # Every way, because the two spellings of filling it conditionally are the
    # same claim — `mod = c ? A : B` is one assignment holding a conditional and
    # `if c then mod = A else mod = B end` is two assignments — and reading one
    # without the other would decide by syntax what Ruby decides by value. Arms
    # that disagree are the undecidable case and answer nothing, which is also
    # what an unassigned local answers: a parameter's value comes from the call
    # site, and that is a different shape entirely.
    def local_constant(name, body)
      writes = nodes(body).filter_map do |node|
        node.value if node.is_a?(Prism::LocalVariableWriteNode) && node.name.to_s == name
      end
      return nil if writes.empty?

      named = writes.flat_map { |value| constant_alternatives(value) }
      return nil if named.empty? || named.any?(&:nil?)

      answers = named.uniq { |constant, dynamic, _| [constant_key(constant), dynamic] }
      return nil unless answers.size == 1

      # Created by ANY of them. `const_defined?(:X) ? const_get(:X) : const_set(:X, …)`
      # is one claim written as two paths — the module is there afterwards either
      # way, and which path ran is exactly what the source does not say.
      constant, dynamic, = answers.first
      [constant, dynamic, named.filter_map { |_, _, creates| creates }.uniq.first]
    end

    # The constants an expression may evaluate to, as `named` answers them, with
    # a conditional read as its branches. Anything else is one expression and so
    # one alternative.
    #
    # `nil` is NO alternative rather than an unnamed one, and a missing branch is
    # that same nil: on such a path the local holds nothing, so `mod.module_eval`
    # raises and no block lands anywhere. Reading past it names the only module
    # the code can reach, which is what the rest of this pass does with a guard
    # (`if @block` changes nothing about which object is meant). Declining it
    # would also make `mod = A if c` and `mod = (if c then A end)` — the same
    # Ruby, written twice — answer differently.
    #
    # An alternative that is some OTHER expression is a different matter and
    # still declines: it may well be a module, and one this pass failed to name.
    def constant_alternatives(value)
      return [] if value.is_a?(Prism::NilNode)
      return [RbsInfer::AST::ConstantReference.named(value)] unless value.is_a?(Prism::IfNode)

      [value.statements, value.subsequent].compact.flat_map do |branch|
        statements = branch.respond_to?(:statements) ? branch.statements : branch
        (statements&.body || []).flat_map { |node| constant_alternatives(node) }
      end
    end

    # Two `named` answers are the same constant when they name the same thing:
    # a written one by its path, a fetched one by the name itself. Prism nodes
    # compare by identity, so the path is what has to be compared.
    def constant_key(constant)
      constant.is_a?(String) ? constant : RbsInfer::Analyzer.extract_constant_path(constant)
    end

    # `<parameter>.extend(<module>)` — every one the body writes, as
    # `[parameter, name, dynamic?]`.
    #
    # ALL of them rather than one, and no count to decline on. Two `class_eval`s
    # behind one name are an ambiguity — only one block can be the one meant —
    # but a hook that extends two modules has simply extended two modules, and
    # at runtime both happen. Same reason `forward_shapes` reports every forward.
    #
    # The receiver must be the parameter itself, with no `singleton_class` hop:
    # unlike a replay, where the hop names the other method table the same `def`s
    # could land in, `base.singleton_class.extend(M)` puts M in a third place
    # again — the singleton's own singleton — and nothing downstream can say that.
    #
    # The `if const_defined?(:ClassMethods)` guard `ActiveSupport::Concern`
    # writes around this is deliberately not read. What it asks is whether the
    # module is there, and `extension_name` answers that with the declarations
    # the pass has actually seen — the same question, decided by the project
    # rather than by re-implementing the condition.
    def inward_module_calls(body, parameters)
      nodes(body).flat_map do |node|
        next [] unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        handed = handed_receiver(call.receiver, parameters)
        next [] unless handed

        receiver_name, hop = handed
        (call.arguments&.arguments || []).filter_map do |argument|
          # Both spellings of naming a module, and the pair says which is which:
          # a constant is syntax and resolves in the file it was WRITTEN in, a
          # `const_get` is data and resolves against the `self` the hook runs on.
          named = RbsInfer::AST::ConstantReference.named(argument)
          [receiver_name, call.name.to_s, hop, *named] if named
        end
      end
    end

    # `<parameter>.<callee>(self)` — handing ourselves to the object that holds
    # the block, which is the only way a target can start an inward replay.
    #
    # Exactly one argument, and it must be `self`: that is what makes the call a
    # request to act ON US, as against any other message this method might send
    # the parameter on the way.
    #
    # ALL of them, unlike the shapes above. A body sending the argument two such
    # messages is forwarding twice — that is what `include` does, and both halves
    # are real:
    #
    #   modules.reverse_each do |mod|
    #     mod.send(:append_features, self)
    #     mod.send(:included, self)
    #   end
    #
    # Reporting one shape and declining when there were two read that as an
    # ambiguity, and it is not one: which of the two leads to a stored block is
    # decided downstream, by whether the callee's keeper actually replays, and
    # `inward_slot` declines there if more than one does. The other shapes have
    # no such downstream evidence — two different ivars behind one `class_eval`
    # is undecidable wherever you ask — so they still decline on the count.
    def forward_shapes(body, parameters)
      nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::CallNode)
        call = dispatched(node)
        handed = handed_receiver(call.receiver, parameters)
        next unless handed
        arguments = call.arguments&.arguments || []
        next unless arguments.size == 1 && arguments.first.is_a?(Prism::SelfNode)

        parameter, singleton = handed
        [parameter, call.name.to_s, singleton]
      end.uniq
    end

    # `@holder ||= Holder.new` plus `@holder.<callee>(…, &block)` in one body.
    #
    # Forwarding the block is the whole claim. What separates a pass-through from
    # any other message the method happens to send its holder is that the block
    # the CALLER wrote arrives at the callee — and it is the only thing that
    # matters here, since the block is the object being relocated. A call that
    # drops it reaches a storage that would keep nothing.
    #
    # The constructor has to sit in this body too. An ivar filled somewhere else
    # is a data-flow question, and this pass answers only what one body shows —
    # the same line `inward_replay_shape` draws when it insists the block come
    # off `self` rather than from wherever a value might have been put.
    def delegation_shape(node)
      block_name = node.parameters&.block&.name&.to_s
      return nil unless block_name

      holders = held_constructions(node.body)
      return nil unless holders.size == 1

      ivar, constant = holders.first

      callees = nodes(node.body).filter_map do |child|
        next unless child.is_a?(Prism::CallNode)
        call = dispatched(child)
        receiver = call.receiver
        next unless receiver.is_a?(Prism::InstanceVariableReadNode) && receiver.name.to_s == ivar
        pass = call.block
        next unless pass.is_a?(Prism::BlockArgumentNode)
        next unless pass.expression.is_a?(Prism::LocalVariableReadNode)
        next unless pass.expression.name.to_s == block_name

        call.name.to_s
      end.uniq

      [constant, callees.first] if callees.size == 1
    end

    # Every ivar this body fills with a `Constant.new`, as `[ivar, constant]`.
    # `@x ||= K.new` and `@x = K.new` say the same thing about what the slot
    # holds. An ivar built from two different constants says nothing decidable
    # and is dropped rather than resolved by write order.
    def held_constructions(body)
      writes = nodes(body).filter_map do |node|
        next unless node.is_a?(Prism::InstanceVariableWriteNode) || node.is_a?(Prism::InstanceVariableOrWriteNode)

        value = node.value
        next unless value.is_a?(Prism::CallNode) && value.name == :new && value.receiver

        [node.name.to_s, value.receiver]
      end

      writes.group_by(&:first).filter_map do |ivar, entries|
        constants = entries.map(&:last)
        names = constants.filter_map { |constant| RbsInfer::Analyzer.extract_constant_path(constant) }.uniq
        [ivar, constants.first] if names.size == 1
      end
    end
  end
end
