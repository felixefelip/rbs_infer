# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/current_attributes_callbacks_generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Rails::CurrentAttributesCallbacksGenerator do
  APP_CONTROLLER = <<~RUBY
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
      before_action :set_authenticated_user

      private

      def set_authenticated_user
        Current.user = current_user
      end
    end
  RUBY

  def generate(resource_types: { "user" => "(User & User::Validated)" }, **controllers)
    Dir.mktmpdir do |dir|
      controllers.each do |path, source|
        full = File.join(dir, "app/controllers", path.to_s)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, source)
      end

      scanner = RbsInfer::Extensions::Rails::BeforeActionScanner.new(app_dir: dir, scopes: resource_types.keys)
      output_dir = File.join(dir, "sig/rbs_infer_current_attributes")
      generator = described_class.new(
        app_dir: dir, output_dir: output_dir, scanner: scanner, resource_types: resource_types
      )
      generator.generate_all

      markers_path = File.join(output_dir, "populated_markers.rbs")
      sidecar_path = File.join(output_dir, ".steep_callbacks.yml")
      [
        File.exist?(markers_path) ? File.read(markers_path) : nil,
        File.exist?(sidecar_path) ? YAML.safe_load(File.read(sidecar_path)) : nil,
      ]
    end
  end

  it "emits the populated marker with the proven resource type" do
    markers, = generate("application_controller.rb" => APP_CONTROLLER)

    expect(markers).to include("class Current")
    expect(markers).to include("module UserPopulated")
    expect(markers).to include("def user: () -> (User & User::Validated)")
    expect { RBS::Parser.parse_signature(markers) }.not_to raise_error
  end

  it "emits constants-only sidecar entries for guarded actions of descendants" do
    _, sidecar = generate(
      "application_controller.rb" => APP_CONTROLLER,
      "posts_controller.rb" => <<~RUBY
        class PostsController < ApplicationController
          def index; end
        end
      RUBY
    )

    expect(sidecar["callbacks"]).to eq([
      {
        "class" => "PostsController",
        "applies_constants" => { "Current" => "singleton(Current) & Current::UserPopulated" },
        "runs_before" => ["index"],
      },
    ])
    # No applies_self — self-narrowing belongs to the Devise sidecar
    expect(sidecar["callbacks"].first).not_to have_key("applies_self")
  end

  it "writes nothing when no guarded handler populates a constant" do
    markers, sidecar = generate(
      "application_controller.rb" => <<~RUBY
        class ApplicationController < ActionController::Base
          before_action :authenticate_user!

          def index; end
        end
      RUBY
    )

    expect(markers).to be_nil
    expect(sidecar).to be_nil
  end
end
