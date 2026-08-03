require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Extensions::Rails::ModuleSelfTypeAnnotator do
  CONCERN_SRC = "module X\n  extend ActiveSupport::Concern\nend\n"
  PLAIN_SRC = "module X\nend\n"

  # A model concern's host comes from the `include` that names it, so these pass
  # an index (felixefelip/rbs_infer#163). The conventions below cover only what
  # no source shows.
  def index_answering(hosts)
    instance_double(RbsInfer::Project::MixinIndex, hosts_of: hosts)
  end

  describe ".entry_for" do
    it "builds both annotations for a model concern, with the AST-cased name" do
      entry = described_class.entry_for(
        path: "app/models/search/record/sqlite.rb",
        module_name: "Search::Record::SQLite",
        source: CONCERN_SRC,
        mixin_index: index_answering(["Search::Record"])
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
        source: PLAIN_SRC,
        mixin_index: index_answering(["Post"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: Post & Post::Taggable"])
    end

    # There is no convention for a model concern any more: its host is always
    # written down, and guessing it from the namespace only ever spoke where the
    # guess was wrong — `Test::Filtrable` got `Test`, a directory, and the
    # CLASSES under `app/models/` got a namespace they are not an instance of.
    it "returns nil for a model concern nobody includes" do
      expect(
        described_class.entry_for(path: "app/models/post/taggable.rb", module_name: "Post::Taggable", source: PLAIN_SRC)
      ).to be_nil
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

  # felixefelip/rbs_infer#163. The conventions above are a guess from a file
  # path; the `include`s written in the sources are what the code says, so they
  # answer first and the guess is left for what no source shows.
  describe "with a mixin index" do
    def index_answering(hosts)
      instance_double(RbsInfer::Project::MixinIndex, hosts_of: hosts)
    end

    it "prefers the written include over the path convention" do
      # The convention reads the namespace, `Test`, which is not a host at all —
      # it is the directory the concern happens to sit in.
      entry = described_class.entry_for(
        path: "app/models/concerns/test/filtrable.rb",
        module_name: "Test::Filtrable",
        source: PLAIN_SRC,
        mixin_index: index_answering(["Post"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: Post & Test::Filtrable"])
    end

    # A union, because `self` is one host at a time. Intersecting them says an
    # object is both, and for two sibling controllers that is a type nothing
    # has — measured on Fizzy, where it cost `Authentication` every
    # postcondition it carried. felixefelip/steep#130 is what makes a union
    # usable here.
    it "unions every host when a module is mixed into more than one" do
      entry = described_class.entry_for(
        path: "app/helpers/posts_helper.rb",
        module_name: "PostsHelper",
        source: PLAIN_SRC,
        mixin_index: index_answering(%w[ERBPostsIndex ERBPostsShow])
      )

      expect(entry["annotations"])
        .to eq(["# @type instance: (ERBPostsIndex & PostsHelper) | (ERBPostsShow & PostsHelper)"])
    end

    it "carries the same hosts into the singleton annotation" do
      entry = described_class.entry_for(
        path: "app/models/eventable.rb",
        module_name: "Eventable",
        source: CONCERN_SRC,
        mixin_index: index_answering(%w[Card Comment])
      )

      expect(entry["annotations"]).to eq([
        "# @type self: (singleton(Card) & singleton(Eventable)) | (singleton(Comment) & singleton(Eventable))",
        "# @type instance: (Card & Eventable) | (Comment & Eventable)"
      ])
    end

    # A top-level concern has no namespace to guess from, so before the index it
    # got no annotation at all.
    it "answers where the convention had nothing to say" do
      entry = described_class.entry_for(
        path: "app/models/trashable.rb",
        module_name: "Trashable",
        source: PLAIN_SRC,
        mixin_index: index_answering(["Card"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: Card & Trashable"])
    end

    it "falls back to the convention when nobody includes the module" do
      entry = described_class.entry_for(
        path: "app/helpers/posts_helper.rb",
        module_name: "PostsHelper",
        source: PLAIN_SRC,
        mixin_index: index_answering([])
      )

      expect(entry["annotations"]).to eq(["# @type instance: ApplicationController & PostsHelper"])
    end
  end
end
