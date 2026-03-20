# frozen_string_literal: true

require "rails/railtie"

module RbsInfer
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/rbs_infer_enumerize.rake", __dir__)
      load File.expand_path("../tasks/rbs_infer_rails_custom.rake", __dir__)
      load File.expand_path("../tasks/rbs_infer_erb.rake", __dir__)
    end
  end
end
