# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../inference/send_call"

module RbsInfer::Project::StoredBlockReplayExpander
  # What a Prism node SAYS, asked without reference to the file it came from.
  #
  # Every method here is a function of the nodes it is handed: which object a
  # call runs on, what a `def` binds its arguments to, whether two nodes can
  # both run. None of them reads a declaration, a provider or an absorbed
  # shape, which is why they are here rather than in `Collector` — that class
  # carries thirty-odd instance variables and these answers depend on none of
  # them (felixefelip/rbs_infer#303).
  #
  # `extend self` rather than `module_function`, and for a reason: the modules
  # that build on this one `include` it, and only `extend self` carries the
  # included methods onto the module's own singleton as well. So
  # `ShapeReader.replay_shape` can reach `nodes` while `NodeReading.nodes`
  # stays callable — and testable — on its own.
  module NodeReading
    extend self

    # What `singleton_class_of` answers for a call written on no receiver at
    # all. A `Symbol` rather than a fabricated node: nothing reads it back as
    # syntax, only compares it.
    IMPLICIT_RECEIVER = :self

    # The names a `def` or a block binds its arguments to. One reader for both:
    # `BlockParametersNode#parameters` IS a `ParametersNode`, so "what does this
    # bind" has one answer regardless of which construct asked.
    #
    # A destructuring target (`|(a, b)|`) is a `MultiTargetNode` and carries no
    # `name`, so it is skipped — the same way a method's would be.
    def parameter_names(params)
      return Set.new unless params.is_a?(Prism::ParametersNode)

      names = params.requireds + params.optionals + params.posts + params.keywords
      names = names.filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
      names << params.rest.name.to_s if params.rest.respond_to?(:name) && params.rest&.name
      Set.new(names)
    end

    # Every name the method can be HANDED an object under. A replay against
    # arbitrary state is what this pass declines to guess about, so the shapes
    # below require their receiver to be one of these rather than any local that
    # happens to be in scope.
    #
    # That is the method's parameters, and also the parameters of a block passed
    # to a call ON one of those names. The question the restriction asks is
    # about PROVENANCE — "did this object reach us from the caller, or did we
    # fetch it from somewhere else in the program" — and a value yielded by a
    # method of a handed object answers it the same way the parameter does.
    # `mod` in `modules.reverse_each { |mod| mod.apply(self) }` is as much
    # something we were handed as `modules` is; restricting the receiver to a
    # parameter NAME missed that, so a DSL forwarding to each of several modules
    # resolved nothing (felixefelip/rbs_infer#253).
    #
    # Deliberately NOT a list of iteration methods. Which of the yielded values
    # is "the element" is a question about the receiver's type, which this
    # source-only pass cannot answer and — since the forward's parameter name is
    # never read again, only its callee — does not need to: `Enumerable#inject`
    # yields the memo first and `each_with_index` an index second, so any
    # first-parameter rule would be wrong for one of them while the provenance
    # claim holds for both.
    #
    # Iterated to a fixed point because the relation is transitive — a nested
    # iteration still yields values that came from the caller — terminating
    # because a body binds finitely many names and the set only grows.
    def handed_names(body, parameters)
      names = parameters.dup

      loop do
        grown = false
        nodes(body).each do |node|
          next unless node.is_a?(Prism::CallNode)
          receiver = node.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode) && names.include?(receiver.name.to_s)
          next unless node.block.is_a?(Prism::BlockNode)

          bound = node.block.parameters
          next unless bound.is_a?(Prism::BlockParametersNode)

          parameter_names(bound.parameters).each { |name| grown = true if names.add?(name) }
        end
        break unless grown
      end

      names
    end

    # The call a node stands for, reading `x.send(:foo, a)` as the `x.foo(a)`
    # it is. `Inference::SendCall` is the one place that knows that spelling
    # (felixefelip/rbs_infer#205) and it answers with a real `Prism::CallNode`,
    # so every matcher below reads `name`, `arguments`, `receiver` and `block`
    # off it exactly as it read them off the original.
    #
    # Reading `node.name` directly answered `send` and left the real callee
    # sitting in the argument list, so every shape below missed the spelling —
    # which is the spelling a caller reaches for when the method is private,
    # and the one the generated `Module#include` pseudo-code writes
    # (`mod.send(:included, self)`), for exactly that reason
    # (felixefelip/rbs_infer#255).
    #
    # `desugar` answers nil for a COMPUTED name, and falling back to the node
    # itself is what declines it: the matchers then see `send` with the name
    # still in the argument list and no shape fits. Which method a computed
    # dispatch runs is a runtime answer, and this pass does not guess.
    def dispatched(node)
      RbsInfer::Inference::SendCall.desugar(node) || node
    end

    # Which object a replay runs ON, as `[parameter name, singleton?]`, or nil
    # when the receiver is not one this pass will move a block onto.
    #
    # `base.class_eval` and `base.singleton_class.class_eval` are the same
    # relocation asked about two different method tables — `base`'s own, and
    # `base`'s singleton — which is exactly the difference between a DSL
    # spelling `included do` and one spelling `class_methods do`. Reading only
    # the bare parameter made the second one no shape at all, so a `def` a human
    # can see landing on the class object was left in the module that wrote it
    # (felixefelip/rbs_infer#267).
    #
    # The parameter restriction is unchanged and is the whole conservatism here:
    # `singleton_class` is a hop to a DIFFERENT OBJECT, and taking it is only
    # safe because that object is decided by the one we were handed. An
    # arbitrary receiver still declines, singleton or not.
    def replayed_on(receiver, parameters)
      return nil unless receiver

      if (inner = singleton_class_of(receiver))
        return nil unless inner.is_a?(Prism::LocalVariableReadNode) && parameters.include?(inner.name.to_s)

        return [inner.name.to_s, true]
      end

      return nil unless receiver.is_a?(Prism::LocalVariableReadNode) && parameters.include?(receiver.name.to_s)

      [receiver.name.to_s, false]
    end

    # The same question for the outward direction, where the replay runs on the
    # DSL's own `self` rather than on something handed to it — `:instance` for
    # `class_eval`, `:singleton` for `singleton_class.class_eval`, nil for a
    # receiver that is neither.
    #
    # The receiver used to go unread here, which happened to be harmless while
    # every shape it could take meant the same thing. It no longer does: the
    # rewrite emits a reopening of the SUBJECT — the class whose body wrote the
    # module call — so a replay written on anything else (`Other.class_eval`) is
    # a block running on a class this pass never resolved, and naming the
    # subject would be an answer about the wrong one.
    def own_receiver(receiver)
      return :instance if receiver.nil? || receiver.is_a?(Prism::SelfNode)
      return :singleton if singleton_class_of(receiver) == IMPLICIT_RECEIVER

      nil
    end

    # The receiver of a `singleton_class` call — the node it is written on,
    # `IMPLICIT_RECEIVER` when it is written on none, or nil when the node is
    # not a `singleton_class` call at all. Three answers rather than two,
    # because "no receiver" is a receiver here: it names the DSL's own `self`.
    #
    # No arguments, because `singleton_class` takes none: a same-named method
    # that does is somebody else's, and it says nothing about a method table.
    def singleton_class_of(node)
      return nil unless node.is_a?(Prism::CallNode)

      call = dispatched(node)
      return nil unless call.name == :singleton_class
      return nil unless (call.arguments&.arguments || []).empty?

      receiver = call.receiver
      return IMPLICIT_RECEIVER if receiver.nil? || receiver.is_a?(Prism::SelfNode)

      receiver
    end

    # Every node in `root`, paired with the branch path it sits on — one
    # `[predicate, taken]` per conditional enclosing it.
    #
    # The predicate NODE is the key, not what it says: nothing here evaluates a
    # condition, and it does not have to. Two nodes under the same `if` with
    # opposite answers cannot both run, whatever the condition is — which is the
    # whole question a deferral asks.
    def branched_nodes(root, path = [])
      return [] unless root

      case root
      when Prism::IfNode
        branched_nodes(root.predicate, path) +
          branched_nodes(root.statements, path + [[root.predicate, true]]) +
          branched_nodes(root.subsequent, path + [[root.predicate, false]])
      when Prism::UnlessNode
        branched_nodes(root.predicate, path) +
          branched_nodes(root.statements, path + [[root.predicate, false]]) +
          branched_nodes(root.else_clause, path + [[root.predicate, true]])
      else
        [[root, path]] + root.compact_child_nodes.flat_map { |child| branched_nodes(child, path) }
      end
    end

    # Whether two paths cannot both be taken — one conditional answered both
    # ways is enough, and is what an `if`/`else` pair is.
    def exclusive?(one, other)
      one.any? do |predicate, taken|
        other.any? { |other_predicate, other_taken| other_predicate.equal?(predicate) && other_taken != taken }
      end
    end

    # The single assignment behind each local in `body`, so a slot parked in a
    # variable reads as the slot. Only single ones: a name written twice names
    # two values, and which one a later read sees is not a question a source
    # walk answers.
    def local_aliases(body)
      writes = nodes(body).select { |node| node.is_a?(Prism::LocalVariableWriteNode) }
      writes.group_by { |node| node.name.to_s }.filter_map do |name, group|
        [name, group.first.value] if group.size == 1
      end.to_h
    end

    def parameter_name(node, parameters)
      node.name.to_s if node.is_a?(Prism::LocalVariableReadNode) && parameters.include?(node.name.to_s)
    end

    def local_read?(node, name)
      node.is_a?(Prism::LocalVariableReadNode) && node.name.to_s == name
    end

    def symbol_name(node)
      node.unescaped.to_s if node.is_a?(Prism::SymbolNode)
    end

    # Whether `self` is anywhere in the value being handed over. `base.deps <<
    # self` and `base.instance_variable_set(:@x, base.deps + [self])` register
    # the same module, and only one of them writes `self` at the top.
    def mentions_self?(node)
      nodes(node).any? { |inner| inner.is_a?(Prism::SelfNode) }
    end

    def bare_or_self?(node)
      node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    def nodes(root)
      return [] unless root

      RbsInfer::Analyzer.find_all_nodes(root) { true }
    end
  end
end
