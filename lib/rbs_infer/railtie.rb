# frozen_string_literal: true

require "rails/railtie"

module RbsInfer
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("extensions/enumerize/tasks/rbs_infer_enumerize.rake", __dir__)
      load File.expand_path("extensions/carrierwave/tasks/rbs_infer_carrierwave.rake", __dir__)
      load File.expand_path("extensions/devise/tasks/rbs_infer_devise.rake", __dir__)
      load File.expand_path("extensions/rails/tasks/rbs_infer_rails_custom.rake", __dir__)
      load File.expand_path("extensions/rails/tasks/rbs_infer_erb.rake", __dir__)
      load File.expand_path("extensions/rails/tasks/rbs_infer_module_self_types.rake", __dir__)
      load File.expand_path("extensions/rails/tasks/rbs_infer_ar_runtime.rake", __dir__)
      load File.expand_path("extensions/rails/tasks/rbs_infer_controller_runtime.rake", __dir__)
    end
  end
end
