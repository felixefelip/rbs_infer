# frozen_string_literal: true

require "set"
require_relative "reflection_scanner"
require_relative "../../../../ast/lexical_constant_resolver"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module Runtime
          # Expands `include SomeConcern` into the concern's own declarations, so
          # a model's reflections are what Active Record would report at runtime
          # rather than only what its own class body spells.
          #
          # An association just as often lives in a concern as in the model:
          #
          #   module User::Notifiable
          #     extend ActiveSupport::Concern
          #     included do
          #       has_many :notifications, dependent: :destroy
          #     end
          #   end
          #
          #   class User < ApplicationRecord
          #     include User::Notifiable
          #   end
          #
          # `User.reflect_on_all_associations` includes `notifications`, so
          # rbs_rails (which reflects at runtime) declares the proxy type — but
          # the AR-runtime generator reads SOURCE, and reading `user.rb` alone
          # sees no `has_many` at all. The getter and the proxy reopen were then
          # never emitted and `user.notifications` had no type
          # (felixefelip/rbs_infer#139).
          #
          # This is the cross-file half of the scan: `ReflectionScanner` reads one
          # file and cannot know who includes what, so it emits a unit per class
          # AND per module and leaves `Include` entries in place; the splice
          # happens here, where every unit is visible.
          #
          # Splicing IN PLACE (rather than appending) is what keeps Rails'
          # semantics: callbacks run in registration order, and a redeclared
          # association replaces the earlier one — so a `has_many` written in both
          # the concern and the class yields the class's, once.
          module ConcernResolver
            module_function

            # units: every `ModelReflections` scanned, classes and modules.
            # Returns the CLASS units only, each with its includes expanded.
            #
            # A class left with nothing to model is KEPT: this list is also the
            # table the element resolver looks classes up in, and a model that
            # declares no association of its own is still a valid element for
            # someone else's `has_many` (felixefelip/rbs_infer#141). Emitting
            # nothing for it is the builder's call, not this one's.
            def resolve(units)
              concerns = index_concerns(units)

              units.select { |unit| unit.kind == :class }
                .group_by(&:class_name)
                .map { |class_name, reopens| merge(class_name, reopens, concerns) }
            end

            # Every reopen of the same class is ONE model: Ruby reopens a class
            # rather than replacing it, so `class Post` written in two files
            # registers the associations of both.
            #
            # Indexing by name and letting one win dropped the other's
            # reflections: `class Post` reopened only to nest `Post::Archiver`
            # erased Post's own `belongs_to :user`, and with it the construction
            # flow of every proxy whose `build` needed that inverse.
            def merge(class_name, reopens, concerns)
              ModelReflections.new(
                path: reopens.first.path,
                class_name: class_name,
                kind: :class,
                body: reopens.flat_map { |unit| expand(unit, concerns, Set.new) }
              )
            end

            # Only MODULES are ever spliced, so only modules are in the lookup
            # table — which also settles what a class and a concern sharing a
            # name resolve to, without the answer depending on scan order.
            def index_concerns(units)
              units.select { |unit| unit.kind == :module }.to_h { |unit| [unit.class_name, unit] }
            end

            # The unit's body with every `Include` replaced by the included
            # module's own (recursively expanded) body. An `include` naming
            # something outside the scanned models — a gem's concern, a plain
            # library module — contributes nothing rather than guessing.
            #
            # `visited` makes a re-include a no-op, matching Ruby (a module
            # already in the ancestor chain is not inserted twice) and cutting
            # any cycle a mutually-including pair would create.
            def expand(unit, concerns, visited)
              return [] if visited.include?(unit.class_name)

              visited << unit.class_name

              unit.body.flat_map do |entry|
                next [entry] unless entry.is_a?(Include)

                concern = lookup(entry.name, unit.class_name, concerns)
                concern ? expand(concern, concerns, visited) : []
              end
            end

            # `include Taggable` inside `class Post` is `Post::Taggable` when that
            # exists — Ruby resolves a bare constant from the enclosing namespace
            # outward, and a concern is conventionally nested under its host.
            def lookup(name, enclosing, concerns)
              found = RbsInfer::AST::LexicalConstantResolver.resolve(
                name: name, enclosing: enclosing
              ) { |candidate| concerns.key?(candidate) }

              found && concerns[found]
            end
          end
        end
      end
    end
  end
end
