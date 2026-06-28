require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/module_self_type_generator"
require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe RbsInfer::Extensions::Rails::ModuleSelfTypeGenerator do
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

  it "emits the sidecar with the declared (AST) casing, not path camelization" do
    in_app(
      "app/models/search/record/sqlite.rb" =>
        "module Search::Record::SQLite\n  extend ActiveSupport::Concern\nend\n"
    ) do |dir|
      out = described_class.new(app_dir: dir).generate
      table = YAML.safe_load(File.read(out))

      entry = table.fetch("app/models/search/record/sqlite.rb")
      expect(entry["anchor"]).to eq("SQLite")
      expect(entry["annotations"]).to include(
        "# @type instance: Search::Record & Search::Record::SQLite"
      )
      expect(entry["annotations"].join).not_to include("Sqlite")
    end
  end

  it "covers models, helpers and controller concerns; skips uncovered files" do
    in_app(
      "app/models/post/taggable.rb"            => "module Post::Taggable\nend\n",
      "app/helpers/posts_helper.rb"            => "module PostsHelper\nend\n",
      "app/controllers/concerns/filterable.rb" => "module Filterable\n  extend ActiveSupport::Concern\nend\n",
      "lib/ignored.rb"                         => "module Ignored\nend\n"
    ) do |dir|
      table = described_class.new(app_dir: dir).build_table

      expect(table.keys).to contain_exactly(
        "app/models/post/taggable.rb",
        "app/helpers/posts_helper.rb",
        "app/controllers/concerns/filterable.rb"
      )
      expect(table["app/helpers/posts_helper.rb"]["annotations"].first).to include("ApplicationController & PostsHelper")
    end
  end

  it "removes a stale sidecar when nothing qualifies" do
    in_app("lib/foo.rb" => "module Foo\nend\n") do |dir|
      out = File.join(dir, described_class::SIDECAR_PATH)
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, "stale")

      described_class.new(app_dir: dir).generate
      expect(File.exist?(out)).to be(false)
    end
  end
end
