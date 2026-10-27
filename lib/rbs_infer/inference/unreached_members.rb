# frozen_string_literal: true

module RbsInfer
  module Inference
    # The methods a class body defines only in a branch the checker found it
    # never takes (felixefelip/steep#378), dropped before anything is emitted:
    #
    #   class Store < Implementation
    #     unless defined?(MriBackend) and self < MriBackend
    #       def [](key) = key   # no Store has this method
    #     end
    #   end
    #
    # Declaring one would give the class a method it does not have, whose
    # signature shadows the one an ancestor's body answers to.
    module UnreachedMembers
      SEPARATORS = { method: "#", class_method: "." }.freeze

      module_function

      def reject!(members, unreached:, owner_of:)
        return if unreached.empty?

        members.reject! do |member|
          separator = SEPARATORS[member.kind] or next false
          unreached.include?("#{owner_of.call(member).delete_prefix("::")}#{separator}#{member.name}")
        end
      end
    end
  end
end
