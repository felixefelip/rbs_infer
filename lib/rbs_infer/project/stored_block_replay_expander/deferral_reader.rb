# frozen_string_literal: true

require "prism"
require_relative "shape_reader"

module RbsInfer::Project::StoredBlockReplayExpander
  # A DSL that hands ITSELF to the target instead of replaying on it, read off
  # the one conditional that writes both outcomes (felixefelip/rbs_infer#300).
  #
  # Three nodes and the branches they sit on — a registration, a replay that
  # the registration excludes, and a drain that rejoins them — described in
  # full on `deferral_shape`. It is the one shape whose answer is a BRANCH
  # rather than a node, so it reads the body through `branched_nodes` where
  # every other shape scans it flat, and that is why it is a module of its own
  # rather than more of `ShapeReader`.
  #
  # `readers` is threaded rather than reached for: a slot can be named through
  # an `attr_reader`, and the readers are the one thing these readings need
  # that a body does not contain. Passing them keeps every method here a
  # function of its arguments, which is the property that makes the whole
  # module checkable on a source string.
  module DeferralReader
    include ShapeReader
    extend self

    # The deferral this method writes, as `[parameter, slot, recall]`, or nil
    # when it always replays where it stands (felixefelip/rbs_infer#300).
    #
    # Three nodes, and the branches they sit on:
    #
    #   * a REGISTRATION — `self` handed into the target's `@slot`;
    #   * a REPLAY — `class_eval` on the target — on the branch the
    #     registration excludes, because a method that does both did neither
    #     conditionally and its target is final;
    #   * a DRAIN — the module's own `@slot` emptied back onto the target — on
    #     the replay's side, since it is what makes the registration a hop
    #     rather than a dead end.
    #
    # The slot joins the first and the third: `self` goes into the target's copy
    # and comes back out of ours, which is one collection seen from its two
    # ends. Without the drain a registered module would simply never run, and
    # the honest answer would be to emit nothing rather than to move the block
    # to a host.
    #
    # One answer or none. Two deferrals in one method is a method this pass
    # cannot say which way it went, and it declines rather than pick.
    def deferral_shape(body, parameters, readers)
      return nil unless body

      branched = branched_nodes(body)
      aliases = local_aliases(body)
      replays = branched.filter_map do |node, path|
        target = inward_replay_at(node, parameters)&.first
        [target, path] if target
      end
      drains = branched.filter_map do |node, path|
        drain = drain_shape(node, parameters, readers)
        [drain, path] if drain
      end

      found = branched.filter_map do |node, path|
        registered = registration_slot(node, parameters, aliases, readers)
        next unless registered

        deferral_through(registered, path, replays, drains)
      end.uniq

      found.first if found.size == 1
    end

    # The `[parameter, slot, recall]` one registration stands for, or nil when
    # no replay and drain answer it.
    def deferral_through(registered, path, replays, drains)
      parameter, slot = registered
      replayed = replays.select { |target, replay_path| target == parameter && exclusive?(path, replay_path) }
      return nil if replayed.empty?

      recalls = drains.filter_map do |(drain_parameter, drain_slot, recall), drain_path|
        next unless drain_parameter == parameter && drain_slot == slot
        next unless exclusive?(path, drain_path)
        next unless replayed.any? { |_, replay_path| !exclusive?(drain_path, replay_path) }

        recall
      end.uniq
      return nil unless recalls.size == 1

      [parameter, slot, recalls.first]
    end

    # `<target's slot> << self` / `.push(self)` / `<target>.instance_variable_set(:@x, … self …)`
    # — `self` coming to rest in state the TARGET owns, as `[parameter, slot]`.
    #
    # The message is not read, and that is the point: `<<`, `push` and `add`
    # are one operation spelled three ways, and a pass that names one of them is
    # matching activesupport rather than reading Ruby (felixefelip/rbs_infer#300).
    # What is read is where the value lands — an ivar of the object we were
    # handed — because that is what makes the target able to replay it later.
    def registration_slot(node, parameters, aliases, readers)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      arguments = call.arguments&.arguments || []
      return nil unless arguments.any? { |argument| mentions_self?(argument) }

      if call.name == :instance_variable_set
        parameter = parameter_name(call.receiver, parameters)
        ivar = symbol_name(arguments.first)
        return [parameter, ivar] if parameter && ivar

        return nil
      end

      target_slot(call.receiver, parameters, aliases, readers)
    end

    # The slot a receiver names on the target, as `[parameter, ivar]`.
    #
    # `base.instance_variable_get(:@x)` names it outright; `base.deps` names it
    # through an `attr_reader`, which is the same slot reached the way a module
    # would let anyone else at it. One local hop is followed, so a DSL that
    # parks the collection in a variable before pushing to it says the same
    # thing as one that does not.
    def target_slot(node, parameters, aliases, readers)
      node = aliases[node.name.to_s] if node.is_a?(Prism::LocalVariableReadNode) && aliases.key?(node.name.to_s)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      parameter = parameter_name(call.receiver, parameters)
      return nil unless parameter

      ivar = if call.name == :instance_variable_get
               symbol_name((call.arguments&.arguments || []).first)
             else
               reader_ivar(call.name.to_s, readers)
             end
      [parameter, ivar] if ivar
    end

    # `@slot.each { |dep| <target>.include(dep) }` — the registrations coming
    # back out, as `[parameter, slot, recall]`.
    #
    # Neither the iteration nor the message is named. Which method walks the
    # collection is the collection's business, and what the DSL re-sends is the
    # DSL's — `recall` is carried rather than assumed precisely so the
    # re-application is resolved as the call site the source writes. What is
    # required is the shape that makes it a hop: each element of OUR slot handed
    # to the target.
    def drain_shape(node, parameters, readers)
      return nil unless node.is_a?(Prism::CallNode)

      block = node.block
      return nil unless block.is_a?(Prism::BlockNode)

      slot = own_slot(node.receiver, readers)
      return nil unless slot

      bound = block.parameters
      return nil unless bound.is_a?(Prism::BlockParametersNode)

      element = parameter_names(bound.parameters).to_a
      return nil unless element.size == 1

      recalls = nodes(block.body).filter_map { |inner| recall_at(inner, parameters, element.first) }.uniq
      return nil unless recalls.size == 1

      parameter, recall = recalls.first
      [parameter, slot, recall]
    end

    # `<target>.include(dep)` inside a drain — the target it re-applies to and
    # the message it re-applies with.
    def recall_at(node, parameters, element)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      parameter = parameter_name(call.receiver, parameters)
      return nil unless parameter

      arguments = call.arguments&.arguments || []
      return nil unless arguments.any? { |argument| local_read?(argument, element) }

      [parameter, call.name.to_s]
    end

    # The ivar a receiver names on the DSL's OWN self — written as the ivar, or
    # reached through a reader, which are the same slot.
    def own_slot(node, readers)
      return nil unless node
      return node.name.to_s if node.is_a?(Prism::InstanceVariableReadNode)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      return nil unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)
      return nil unless (call.arguments&.arguments || []).empty?

      reader_ivar(call.name.to_s, readers)
    end

    # `<parameter>.instance_variable_set(:@x, …)`, as `[parameter, ivar]` — what
    # a DSL runs on the objects it is handed, and so what says which objects
    # hold `@x`.
    #
    # It is the other half of `deferral_shape`: the shape above says the DSL
    # defers, and this one says WHOSE branch is taken, because the objects
    # holding the slot are the ones this method ran for.
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

    # The ivar an `attr_reader` of that name reaches, when exactly one does.
    def reader_ivar(name, readers)
      ivars = readers.select { |_, reader_name, _| reader_name == name }.map(&:last).uniq
      ivars.first if ivars.size == 1
    end
  end
end
