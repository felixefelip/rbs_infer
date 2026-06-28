# frozen_string_literal: true

require_relative "../module_self_type_generator"

namespace :rbs_infer do
  namespace :module_self_types do
    desc "Generate the module/concern self-type sidecar for Steep (sig/generated/.steep_module_self_types.yml)"
    task :all do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd
      out = RbsInfer::Extensions::Rails::ModuleSelfTypeGenerator.new(app_dir: app_dir).generate
      puts "Generated module self-types sidecar: #{out}"
    end
  end
end
