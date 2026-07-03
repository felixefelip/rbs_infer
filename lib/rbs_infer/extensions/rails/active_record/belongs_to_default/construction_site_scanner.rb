# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      module ActiveRecord
        module BelongsToDefault
          CONSTRUCTORS = %i[new build create create!].freeze

          # A place a belongs_to-default model is constructed. Two kinds:
          #
          #   * :association — `owner.assignments.create!(args)`. The record's
          #     inverse belongs_to (`post`) is set from the association OWNER, so
          #     `post` is non-nil ⇒ the default's deref is safe.
          #   * :direct — `Assignment.create!(post: p, owner: u)`. Belongs_to
          #     attrs passed as literal kwargs are set from the literal; attrs
          #     that come from a ParamsBag (or a bare FK like `post_id:`) stay
          #     nilable — so the default's deref of a params-sourced association
          #     is (correctly) still flagged.
          ConstructionSite = Struct.new(
            :kind,               # :association | :direct
            :model,              # ModelReflections being built
            :owner_class,        # class declaring the has_many (:association only)
            :inverse_belongs_to, # BelongsTo the owner-setter targets (:association only)
            :literal_belongs_to, # [String] belongs_to names set via a non-nil literal kwarg
            :path,
            :location,           # { line:, column: } of the call
            keyword_init: true
          )

          # Maps a `has_many` association name → the belongs_to-default models it
          # can build, with the declaring owner class. Built once over all
          # models so the caller scan is a cheap name lookup.
          class AssociationIndex
            Entry = Struct.new(:owner_class, :model, :inverse_belongs_to, keyword_init: true)

            def initialize(models)
              @by_class = models.to_h { |m| [m.class_name, m] }
              @by_has_many = Hash.new { |h, k| h[k] = [] }
              @default_model_names = models.select { |m| m.default_associations.any? }
                                           .map(&:class_name).to_set

              models.each do |owner|
                owner.has_many.each do |assoc|
                  element = @by_class[assoc.class_name]
                  next unless element && element.default_associations.any?

                  @by_has_many[assoc.name] << Entry.new(
                    owner_class: owner.class_name,
                    model: element,
                    inverse_belongs_to: element.inverse_belongs_to_for(owner.class_name)
                  )
                end
              end
            end

            def any?
              @default_model_names.any?
            end

            # Entries for a `has_many` name (`"assignments"`), or [].
            def has_many_entries(name)
              @by_has_many[name]
            end

            def default_model?(class_name)
              @default_model_names.include?(class_name)
            end

            def model_named(class_name)
              @by_class[class_name]
            end
          end

          # Scans a caller source for construction sites of belongs_to-default
          # models. Returns [ConstructionSite].
          module ConstructionSiteScanner
            module_function

            def scan(path:, source:, index:)
              result = Prism.parse(source)
              return [] unless result.success?

              RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::CallNode) }
                                .filter_map { |call| site_for(call, path, index) }
            end

            def site_for(call, path, index)
              return nil unless CONSTRUCTORS.include?(call.name)

              recv = call.receiver
              return nil unless recv.is_a?(Prism::CallNode) || recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)

              if recv.is_a?(Prism::CallNode) && recv.receiver
                association_site(call, recv, path, index)
              else
                direct_site(call, recv, path, index)
              end
            end

            # `owner.assignments.create!(args)` — `recv` is the `.assignments`
            # call, whose own receiver is the owner.
            def association_site(call, recv, path, index)
              entries = index.has_many_entries(recv.name.to_s)
              return nil if entries.empty?

              entry = entries.first
              ConstructionSite.new(
                kind: :association,
                model: entry.model,
                owner_class: entry.owner_class,
                inverse_belongs_to: entry.inverse_belongs_to,
                literal_belongs_to: literal_belongs_to(call, entry.model),
                path: path,
                location: call_location(call)
              )
            end

            # `Assignment.create!(args)` — `recv` is the model constant.
            def direct_site(call, recv, path, index)
              class_name = RbsInfer::Analyzer.extract_constant_path(recv)&.delete_prefix("::")
              return nil unless class_name && index.default_model?(class_name)

              model = index.model_named(class_name)
              return nil unless model

              ConstructionSite.new(
                kind: :direct,
                model: model,
                literal_belongs_to: literal_belongs_to(call, model),
                path: path,
                location: call_location(call)
              )
            end

            # Belongs_to names set from a provably-non-nil literal kwarg at the
            # call-site (`owner: User.new`, `owner: SOME_CONST`). A kwarg sourced
            # from a local/method/params (`owner: current_user`) or a bare FK
            # (`post_id:`) is NOT included — it can't be proven non-nil, so the
            # attr stays nilable.
            def literal_belongs_to(call, model)
              belongs_to_names = model.belongs_to.map(&:name).to_set
              hash = call.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) }
              return [] unless hash

              hash.elements.filter_map do |elem|
                next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)

                key = elem.key.value.to_s
                next unless belongs_to_names.include?(key) && non_nil_literal?(elem.value)

                key
              end
            end

            # An expression Steep can prove non-nil without context: a `.new`
            # constructor call or a constant reference.
            def non_nil_literal?(node)
              (node.is_a?(Prism::CallNode) && node.name == :new) ||
                node.is_a?(Prism::ConstantReadNode) ||
                node.is_a?(Prism::ConstantPathNode)
            end

            def call_location(call)
              loc = call.location
              { line: loc.start_line, column: loc.start_column }
            end
          end
        end
      end
    end
  end
end
