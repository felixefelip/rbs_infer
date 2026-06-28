module RbsInfer
  module Extensions
    module Rails
      # Computes the `# @type self:` / `# @type instance:` annotation for a
      # concern/module, to be injected by Steep's generic
      # `Steep::Source::ModuleSelfTypes.inject` (felixefelip/rbs_infer#52).
      #
      # This is the Rails-aware half that used to live inside Steep: it knows
      # the path conventions (models / helpers / controller concerns), the
      # including-class rule, and concern detection. Unlike the old Steep code
      # it does NOT camelize the file path to get the module name — the caller
      # passes the real name from the AST (`Analyzer#target_class`), so acronyms
      # (`SQLite`, `OAuth`) keep their declared casing.
      module ModuleSelfTypeAnnotator
        MODELS_PREFIX = "app/models/"
        HELPERS_PREFIX = "app/helpers/"
        CONTROLLER_CONCERNS_PREFIX = "app/controllers/concerns/"

        module_function

        # @param path [String] source path (e.g. "app/models/search/record/sqlite.rb")
        # @param module_name [String] the real FQN from the AST (e.g. "Search::Record::SQLite")
        # @param source [String] the file's source (for concern detection)
        # @return [Hash, nil] `{ "anchor" => leaf, "annotations" => [lines] }`, or
        #   nil when the file isn't a covered module/concern.
        def entry_for(path:, module_name:, source:)
          return nil if module_name.nil? || module_name.empty?

          including_class = including_class_for(path, module_name)
          return nil unless including_class

          anchor = module_name.split("::").last
          is_concern = source.include?("extend ActiveSupport::Concern")

          { "anchor" => anchor, "annotations" => annotations(module_name, including_class, is_concern) }
        end

        # The class a concern/module is mixed into. Helpers and controller
        # concerns mix into ApplicationController by Rails convention; a model
        # concern mixes into its enclosing namespace (`Post::Taggable` → `Post`).
        # Returns nil when the file isn't under a covered root, or a model
        # concern has no namespace to derive the host from.
        def including_class_for(path, module_name)
          path = path.to_s
          return "ApplicationController" if path.include?(HELPERS_PREFIX)
          return "ApplicationController" if path.include?(CONTROLLER_CONCERNS_PREFIX)
          return nil unless path.include?(MODELS_PREFIX)

          parts = module_name.split("::")
          return nil if parts.size < 2

          parts[0..-2].join("::")
        end

        def annotations(module_name, including_class, is_concern)
          instance = "# @type instance: #{including_class} & #{module_name}"
          return [instance] unless is_concern

          self_line = "# @type self: singleton(#{including_class}) & singleton(#{module_name})"
          [self_line, instance]
        end
      end
    end
  end
end
