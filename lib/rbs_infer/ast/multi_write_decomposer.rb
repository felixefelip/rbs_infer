# frozen_string_literal: true

module RbsInfer::AST
  # `@a, @b = x, y` assigns exactly what `@a = x; @b = y` assigns, but Prism
  # gives it a different shape: one `MultiWriteNode` whose targets are
  # `InstanceVariableTargetNode`s (no `.value` of their own). Every visitor
  # keyed on `InstanceVariableWriteNode` therefore misses it, and the ivar is
  # left `untyped` even though the param it came from is fully typed
  # (felixefelip/rbs_infer#183).
  #
  # This is the one place that decides how a multiple assignment pairs up, so
  # the consumers keep their own semantics and only gain the shape.
  #
  # The pairing is deliberately narrow: it fires only when the values are an
  # array literal, the arities match, and neither side splats. Those are the
  # cases where the target/value correspondence is positional and certain.
  # Everything else is left alone:
  #
  #   @a, @b = pair          # one value destructured at runtime
  #   @a, *@rest = 1, 2, 3   # a splat redistributes the elements
  #   @a, (@b, @c) = 1, [2, 3]
  #
  # Guessing there would be worse than the honest `untyped` those already get.
  module MultiWriteDecomposer
    module_function

    # `[[InstanceVariableTargetNode, value_node], ...]` for the ivar targets of
    # a multiple assignment, or `[]` when the node isn't one or the pairing
    # isn't decidable. Non-ivar targets (locals, constants, `self.x =`) are
    # dropped — callers here only ever ask about ivars.
    def ivar_pairs(node)
      return [] unless node.is_a?(Prism::MultiWriteNode)
      # A splat on either side redistributes the values; positions stop lining up.
      return [] if node.rest
      return [] unless node.rights.empty?

      value = node.value
      return [] unless value.is_a?(Prism::ArrayNode)

      elements = value.elements
      return [] if elements.any? { |element| element.is_a?(Prism::SplatNode) }
      return [] unless node.lefts.size == elements.size

      node.lefts.zip(elements).select { |target, _| target.is_a?(Prism::InstanceVariableTargetNode) }
    end

    # Same pairing, as `[["name_without_at", value_node], ...]` — the form most
    # consumers want, since they all strip the leading `@`.
    def ivar_name_pairs(node)
      ivar_pairs(node).map { |target, value| [target.name.to_s.sub(/\A@/, ""), value] }
    end

    # Every ivar name a multiple assignment writes, regardless of whether the
    # values can be paired up. Definite-initialization only asks "was `@x`
    # assigned here?", which is answerable for `@a, *@rest = whatever` too.
    def ivar_target_names(node)
      return [] unless node.is_a?(Prism::MultiWriteNode)

      targets = node.lefts + [node.rest].compact + node.rights
      targets.filter_map do |target|
        target = target.expression if target.is_a?(Prism::SplatNode)
        target.name.to_s.sub(/\A@/, "") if target.is_a?(Prism::InstanceVariableTargetNode)
      end
    end
  end
end
