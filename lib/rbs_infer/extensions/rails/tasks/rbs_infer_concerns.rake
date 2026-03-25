# frozen_string_literal: true

require_relative "../concern_annotation_generator"

namespace :rbs_infer do
  namespace :concerns do
    desc "Inject Steep @type self/@type instance annotations into module and concern files"
    task :annotate do
      app_dir = defined?(Rails) ? Rails.root.to_s : Dir.pwd

      generator = RbsInfer::Extensions::Rails::ConcernAnnotationGenerator.new(
        app_dir: app_dir
      )
      generator.generate_all

      puts "Annotated concern and module files in app/models/"
    end
  end
end
