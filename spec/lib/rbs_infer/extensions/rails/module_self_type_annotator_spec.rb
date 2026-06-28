require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Extensions::Rails::ModuleSelfTypeAnnotator do
  CONCERN_SRC = "module X\n  extend ActiveSupport::Concern\nend\n"
  PLAIN_SRC = "module X\nend\n"

  describe ".entry_for" do
    it "builds both annotations for a model concern, with the AST-cased name" do
      entry = described_class.entry_for(
        path: "app/models/search/record/sqlite.rb",
        module_name: "Search::Record::SQLite",
        source: CONCERN_SRC
      )

      expect(entry["anchor"]).to eq("SQLite")
      expect(entry["annotations"]).to eq([
        "# @type self: singleton(Search::Record) & singleton(Search::Record::SQLite)",
        "# @type instance: Search::Record & Search::Record::SQLite"
      ])
    end

    it "builds only the instance annotation for a plain model module" do
      entry = described_class.entry_for(
        path: "app/models/post/taggable.rb",
        module_name: "Post::Taggable",
        source: PLAIN_SRC
      )

      expect(entry["annotations"]).to eq(["# @type instance: Post & Post::Taggable"])
    end

    it "uses ApplicationController as the host for helpers" do
      entry = described_class.entry_for(
        path: "app/helpers/posts_helper.rb",
        module_name: "PostsHelper",
        source: PLAIN_SRC
      )

      expect(entry["annotations"]).to eq(["# @type instance: ApplicationController & PostsHelper"])
    end

    it "uses ApplicationController as the host for controller concerns" do
      entry = described_class.entry_for(
        path: "app/controllers/concerns/filter_configuration.rb",
        module_name: "FilterConfiguration",
        source: CONCERN_SRC
      )

      expect(entry["annotations"]).to include(
        "# @type self: singleton(ApplicationController) & singleton(FilterConfiguration)",
        "# @type instance: ApplicationController & FilterConfiguration"
      )
    end

    it "returns nil for a file outside the covered roots" do
      expect(described_class.entry_for(path: "lib/foo.rb", module_name: "Foo", source: PLAIN_SRC)).to be_nil
    end

    it "returns nil for a model module without a namespace (no host to derive)" do
      expect(described_class.entry_for(path: "app/models/trashable.rb", module_name: "Trashable", source: PLAIN_SRC)).to be_nil
    end

    it "returns nil for a nil/empty module name" do
      expect(described_class.entry_for(path: "app/models/x.rb", module_name: nil, source: PLAIN_SRC)).to be_nil
    end
  end
end
