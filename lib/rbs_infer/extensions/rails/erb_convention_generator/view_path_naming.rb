# frozen_string_literal: true

module RbsInfer
  module Extensions
    module Rails
      class ErbConventionGenerator
        module ViewPathNaming
          # Convert view relative path to ERB class name.
          #   "posts/show.html.erb"               → "ERBPostsShow"
          #   "posts/_form.html.erb"              → "ERBPartialPostsForm"
          #   "admin/posts/show.html.erb"         → "ERBAdminPostsShow"
          #   "layouts/application.html.erb"      → "ERBLayoutsApplication"
          #   "user_mailer/welcome.html.erb"      → "ERBUserMailerWelcome"
          def erb_class_name(view_relative)
            path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
            parts = path.split("/")
            filename = parts.pop
            return nil unless filename

            is_partial = filename.start_with?("_")
            filename = filename.sub(/\A_/, "") if is_partial

            segments = (parts + [filename]).map { |s| s.split(/[_-]/).map(&:capitalize).join }

            prefix = is_partial ? "ERBPartial" : "ERB"
            "#{prefix}#{segments.join}"
          end

          # Extract the partial key from a view-relative path.
          # "posts/_form.html.erb" → "posts/form"
          def partial_key_from_view_relative(view_relative)
            path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
            parts = path.split("/")
            filename = parts.pop
            return nil unless filename&.start_with?("_")

            parts.push(filename.sub(/\A_/, ""))
            parts.join("/")
          end

          # Parse view path to extract controller class and action.
          # Returns nil for partials and layouts (no controller association).
          def parse_view_path(view_relative)
            path = view_relative.sub(/\.(html|turbo_stream)\.erb\z/, "")
            parts = path.split("/")
            filename = parts.pop

            return nil if filename&.start_with?("_")
            return nil if parts.first == "layouts"
            return nil if parts.empty?

            controller_name = parts.join("/")
            controller_class = parts.map { |s| s.split(/[_-]/).map(&:capitalize).join }.join("::") + "Controller"

            { controller_name: controller_name, controller_class: controller_class, action: filename }
          end

          def find_controller_file(controller_name)
            file = File.join(@app_dir, "app/controllers/#{controller_name}_controller.rb")
            File.exist?(file) ? file : nil
          end
        end
      end
    end
  end
end
