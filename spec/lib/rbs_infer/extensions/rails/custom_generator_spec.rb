# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/custom_generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::Rails::CustomGenerator do
  # Build a throwaway app dir with the given helper files (relative path =>
  # source) and optional config files, run the generator, and return the
  # generated ActionViewContext RBS.
  def action_view_context(helpers:, config: {})
    Dir.mktmpdir do |dir|
      helpers.each do |rel, source|
        path = File.join(dir, "app/helpers", rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      config.each do |rel, source|
        path = File.join(dir, "config", rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end

      output_dir = File.join(dir, "sig/rbs_rails_custom")
      described_class.new(output_dir: output_dir, app_dir: dir, source_files: []).generate_all
      File.read(File.join(output_dir, "action_view_context.rbs"))
    end
  end

  it "includes every app helper module by default (include_all_helpers on)" do
    rbs = action_view_context(helpers: {
      "application_helper.rb" => "module ApplicationHelper\nend\n",
      "posts_helper.rb" => "module PostsHelper\nend\n",
      "sugestoes_helper.rb" => "module SugestoesHelper\nend\n",
    })

    expect(rbs).to include("include ApplicationHelper")
    expect(rbs).to include("include PostsHelper")
    expect(rbs).to include("include SugestoesHelper")
    expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
  end

  it "names namespaced helpers by the path -> constant convention" do
    rbs = action_view_context(helpers: {
      "admin/widgets_helper.rb" => "module Admin\n  module WidgetsHelper\n  end\nend\n",
    })

    expect(rbs).to include("include Admin::WidgetsHelper")
  end

  it "emits helpers sorted, for deterministic collision order" do
    rbs = action_view_context(helpers: {
      "posts_helper.rb" => "module PostsHelper\nend\n",
      "application_helper.rb" => "module ApplicationHelper\nend\n",
    })

    expect(rbs.index("include ApplicationHelper")).to be < rbs.index("include PostsHelper")
  end

  it "falls back to ApplicationHelper only when include_all_helpers is disabled" do
    rbs = action_view_context(
      helpers: {
        "application_helper.rb" => "module ApplicationHelper\nend\n",
        "posts_helper.rb" => "module PostsHelper\nend\n",
      },
      config: {
        "application.rb" => <<~RUBY,
          module Dummy
            class Application < Rails::Application
              config.action_controller.include_all_helpers = false
            end
          end
        RUBY
      }
    )

    expect(rbs).to include("include ApplicationHelper")
    expect(rbs).not_to include("include PostsHelper")
  end
end
