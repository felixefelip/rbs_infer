# frozen_string_literal: true

require "prism"

module RbsInfer
  module Inference
    # Where a rest parameter sits in a list of positional parameter NAMES, and what it is
    # called.
    #
    # Three collectors map a call site's positional arguments onto such a list by index —
    # cross-class calls, `Klass.new` calls, and intra-class calls. All three need one extra
    # fact the names alone cannot carry: at which index the one-to-one mapping stops and
    # every remaining argument starts describing the SAME parameter. A rest param's name is
    # therefore marked in the list itself, and this is the only place that knows how.
    #
    # In-band rather than a parallel structure because it is positional information about
    # that very list, and it travels through three layers of constructor kwargs to reach
    # the collectors. Inert everywhere else: the other consumers compare these names
    # against keyword keys, which a `*`-prefixed name can never equal.
    module RestParamMarker
      PREFIX = "*"

      def self.mark(name) = "#{PREFIX}#{name}"

      # The name behind the marker, or nil for an ordinary parameter name — so a consumer
      # asks "is this the rest param, and what is it called?" in one call.
      def self.unmark(name)
        name&.start_with?(PREFIX) ? name.delete_prefix(PREFIX) : nil
      end

      # Where the rest parameter sits in `names`, or nil when there is none.
      def self.index_in(names) = names.index { |name| unmark(name) }

      # The rest parameter's name for a def's parameters, or nil when it has none: an
      # anonymous `*` (and the implicit rest of `def foo(a,)`) is a parameter no type
      # substitution can reach, since that substitution is keyed by name.
      def self.name_from(params)
        rest = params.rest if params.respond_to?(:rest)
        return unless rest.is_a?(Prism::RestParameterNode)

        rest.name&.to_s
      end
    end
  end
end
