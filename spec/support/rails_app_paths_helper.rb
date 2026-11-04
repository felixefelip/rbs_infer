# frozen_string_literal: true

require "rails/paths"
require "rbs_infer/extensions/rails/app_paths"

module RailsAppPathsHelper
  Application = Struct.new(:paths)

  PACK_PATHS = %w[app app/controllers app/helpers app/models app/views config/routes].freeze

  def rails_app_paths(app_dir, packs: [])
    root = ::Rails::Paths::Root.new(app_dir)
    root.add "app", eager_load: true, glob: "{*,*/concerns}"
    %w[app/controllers app/helpers app/models app/views].each { |key| root.add key, eager_load: true }
    root.add "config/routes", glob: "**/*.rb"

    packs.each do |pack|
      PACK_PATHS.each { |key| root[key] << File.join(pack, key) }
    end

    RbsInfer::Extensions::Rails::AppPaths.of(Application.new(root))
  end
end
