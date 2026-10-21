# frozen_string_literal: true

module RbsInfer
  module Signatures
    # Reconciles the members of a target with what other signatures already
    # declare for them, before anything is emitted.
    class ForeignDeclarations
      ATTR_HALVES = { attr_reader: %i[attr_reader], attr_writer: %i[attr_writer],
                      attr_accessor: %i[attr_reader attr_writer] }.freeze

      def initialize(resolver:, owner_of:, excluding_suffix:)
        @resolver = resolver
        @owner_of = owner_of
        @excluding_suffix = excluding_suffix
      end

      def reconcile!(members)
        confirm_overloading!(members)
        defer_unoverloadable!(members)
      end

      private

      # `# @rbs_infer |...` above a def asks for RBS's overloading form (`... | ...`), which
      # puts our signature AHEAD of one something else already declares instead of colliding
      # with it. The marker states intent; this confirms it, because `| ...` with nothing to
      # overload is an `InvalidOverloadMethodError` — the same class of hard failure, poisoning
      # the whole environment, that it exists to avoid. A marker on a method nobody else
      # declares silently emits the plain form rather than breaking the run.
      #
      # Our own previous output is excluded: it already declares the method, and confirming
      # against it would be circular — a method only we declare would gain `| ...` and then
      # have nothing left to overload.
      #
      # Asked of the member's OWNER, not of the target. A member in a module nested inside
      # the target belongs to `Target::Owner` (the `#{target}::#{owner}` join `owner_of`
      # makes), and asking under the target's own name finds nothing —
      # which drops the marker and emits the plain form, i.e. the duplicate declaration the
      # marker is there to avoid. It fails that way silently: RBS only raises when something
      # BUILDS the class, so a collision nothing references yet sits in the environment
      # unexercised. `ActiveSupport::Concern` is a nested module in exactly that position.
      def confirm_overloading!(members)
        members.select(&:overloading).each do |member|
          confirmed = @resolver.foreign_plain_declaration?(@owner_of.call(member), member.name,
                                                           singleton: member.kind == :class_method,
                                                           excluding_suffix: @excluding_suffix)
          member.overloading = false unless confirmed
        end
      end

      # An `alias` or an `attr_*` has no overloading form, so restating one another
      # signature already declares is a duplicate that takes down the whole class.
      # The alias is left to that signature; each colliding half of an attr is
      # emitted as an overloading `def` instead, ahead of the other declaration.
      def defer_unoverloadable!(members)
        members.reject! do |member|
          %i[alias singleton_alias].include?(member.kind) &&
            declared?(member, member.name, singleton: member.kind == :singleton_alias)
        end
        members.replace(members.flat_map { |member| attr_halves(member) })
      end

      def attr_halves(attr)
        return [attr] unless ATTR_HALVES.key?(attr.kind) && !attr.singleton

        halves = ATTR_HALVES.fetch(attr.kind).map do |kind|
          attr.dup.tap do |half|
            half.kind = kind
            half.overloading = declared?(attr, half_method_name(attr, kind), singleton: false)
          end
        end
        halves.any?(&:overloading) ? halves : [attr]
      end

      def half_method_name(attr, kind) = kind == :attr_writer ? "#{attr.name}=" : attr.name

      def declared?(member, method_name, singleton:)
        @resolver.foreign_own_declaration?(@owner_of.call(member), method_name, singleton: singleton,
                                                                                excluding_suffix: @excluding_suffix)
      end
    end
  end
end
