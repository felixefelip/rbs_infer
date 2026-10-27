# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # The branches Steep proved cannot run (`Ruby::UnreachableBranch`), asked of
      # the Parser nodes the same typing holds.
      class DeadBranches
        def initialize(typing)
          @ranges = typing.errors.filter_map do |error|
            error.node&.loc&.expression if error.is_a?(Steep::Diagnostic::Ruby::UnreachableBranch)
          end
        end

        def cover?(node)
          range = node.loc&.expression or return false

          @ranges.any? { |dead| dead.begin_pos <= range.begin_pos && range.end_pos <= dead.end_pos }
        end
      end
    end
  end
end
