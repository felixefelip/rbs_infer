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
            # Returns the CLASS units only, each with its includes expanded and
            # the ones left with nothing to model dropped.
            def resolve(units)
              by_name = units.to_h { |unit| [unit.class_name, unit] }

              units.select { |unit| unit.kind == :class }.filter_map do |unit|
                resolved = ModelReflections.new(
                  path: unit.path,
                  class_name: unit.class_name,
                  kind: :class,
                  body: expand(unit, by_name, Set.new)
                )
                resolved unless resolved.empty?
              end
            end

            # The unit's body with every `Include` replaced by the included
            # module's own (recursively expanded) body. An `include` naming
            # something outside the scanned models — a gem's concern, a plain
            # library module — contributes nothing rather than guessing.
            #
            # `visited` makes a re-include a no-op, matching Ruby (a module
            # already in the ancestor chain is not inserted twice) and cutting
            # any cycle a mutually-including pair would create.
            def expand(unit, by_name, visited)
              return [] if visited.include?(unit.class_name)

              visited << unit.class_name

              unit.body.flat_map do |entry|
                next [entry] unless entry.is_a?(Include)

                concern = lookup(entry.name, unit.class_name, by_name)
                concern && concern.kind == :module ? expand(concern, by_name, visited) : []
              end
            end

            # `include Taggable` inside `class Post` is `Post::Taggable` when that
            # exists — Ruby resolves a bare constant from the enclosing namespace
            # outward, and a concern is conventionally nested under its host.
            def lookup(name, enclosing, by_name)
              found = RbsInfer::AST::LexicalConstantResolver.resolve(
                name: name, enclosing: enclosing
              ) { |candidate| by_name.key?(candidate) }

              found && by_name[found]
            end
          end
        end
      end
    end
  end
end
