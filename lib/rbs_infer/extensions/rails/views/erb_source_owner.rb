# frozen_string_literal: true

require_relative "path_naming"
require_relative "../../../project/source_owners"

module RbsInfer
  module Extensions
    module Rails
      module Views
        # Answers the `Project::SourceOwners` question for ERB templates:
        # `app/views/posts/edit.html.erb` is the body of `ERBPostsEdit`.
        #
        # This is the convention half of ERB support. Reading the template as Ruby is
        # format knowledge and lives in the core (`ParseCache`); knowing which class it
        # belongs to is a Rails layout convention and belongs here. It is the same mapping
        # the view-runtime generator uses to NAME the class, and the same one Steep's ERB
        # convention uses to attach `@type self_method:` — one convention, stated once.
        module ErbSourceOwner
          extend PathNaming
          module_function

          # Gate on the extension first: this is asked once per indexed file.
          def owner_class(path)
            path = path.to_s
            return nil unless path.end_with?(".erb")

            relative = path[%r{(?:\A|/)app/views/(.+)\z}, 1] or return nil
            erb_class_name(relative)
          end

          # The template compiles to a method at runtime, and both the view-runtime
          # generator and Steep's ERB convention name it `__rbs_infer__body`. That name is
          # this convention's, so it is stated here rather than assembled by the core.
          def self_method(path)
            klass = owner_class(path) or return nil

            "#{klass}#__rbs_infer__body"
          end

          RbsInfer::Project::SourceOwners.register(self)
        end
      end
    end
  end
end
