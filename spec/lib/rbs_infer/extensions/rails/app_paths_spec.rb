# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../../support/rails_app_paths_helper"

RSpec.describe RbsInfer::Extensions::Rails::AppPaths do
  include RailsAppPathsHelper

  def in_app(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end

  describe ".conventional" do
    it "answers the directory under the app root" do
      in_app("app/controllers/posts_controller.rb" => "") do |dir|
        paths = described_class.conventional(dir)

        expect(paths.roots("app/controllers")).to eq([File.join(dir, "app/controllers")])
      end
    end

    it "answers no root for a directory the app does not have" do
      in_app("app/models/post.rb" => "") do |dir|
        expect(described_class.conventional(dir).roots("app/jobs")).to be_empty
      end
    end
  end

  describe ".of" do
    it "answers every root the application registers for a key, in its order" do
      in_app("app/views/layouts/application.html.erb" => "",
             "packs/billing/app/views/invoices/show.html.erb" => "") do |dir|
        paths = rails_app_paths(dir, packs: ["packs/billing"])

        expect(paths.roots("app/views")).to eq(
          [File.join(dir, "app/views"), File.join(dir, "packs/billing/app/views")]
        )
      end
    end

    it "derives a key the application does not register from its app roots" do
      in_app("app/jobs/application_job.rb" => "",
             "packs/billing/app/jobs/charge_job.rb" => "") do |dir|
        paths = rails_app_paths(dir, packs: ["packs/billing"])

        expect(paths.roots("app/jobs")).to eq(
          [File.join(dir, "app/jobs"), File.join(dir, "packs/billing/app/jobs")]
        )
      end
    end

    it "drops a registered root that does not exist" do
      in_app("packs/billing/app/controllers/invoices_controller.rb" => "") do |dir|
        paths = rails_app_paths(dir, packs: ["packs/billing"])

        expect(paths.roots("app/controllers")).to eq([File.join(dir, "packs/billing/app/controllers")])
      end
    end
  end

  describe "#files" do
    it "keys each file by its path under its root, the first root winning a clash" do
      in_app("app/views/shared/_header.html.erb" => "",
             "packs/billing/app/views/shared/_header.html.erb" => "",
             "packs/billing/app/views/invoices/show.html.erb" => "") do |dir|
        files = rails_app_paths(dir, packs: ["packs/billing"]).files("app/views", "**/*.html.erb")

        expect(files).to eq(
          "invoices/show.html.erb" => File.join(dir, "packs/billing/app/views/invoices/show.html.erb"),
          "shared/_header.html.erb" => File.join(dir, "app/views/shared/_header.html.erb")
        )
      end
    end
  end

  describe "#find" do
    it "answers the file under the first root that has it" do
      in_app("packs/billing/app/helpers/invoices_helper.rb" => "") do |dir|
        paths = rails_app_paths(dir, packs: ["packs/billing"])

        expect(paths.find("app/helpers", "invoices_helper.rb"))
          .to eq(File.join(dir, "packs/billing/app/helpers/invoices_helper.rb"))
        expect(paths.find("app/helpers", "posts_helper.rb")).to be_nil
      end
    end
  end
end
