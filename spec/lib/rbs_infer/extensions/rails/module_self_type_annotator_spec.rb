require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Extensions::Rails::ModuleSelfTypeAnnotator do
  CONCERN_SRC = "module X\n  extend ActiveSupport::Concern\nend\n"
  PLAIN_SRC = "module X\nend\n"

  # A model concern's host comes from the `include` that names it, so these pass
  # an index (felixefelip/rbs_infer#163). The conventions below cover only what
  # no source shows.
  def index_answering(hosts, extenders: [])
    instance_double(RbsInfer::Project::MixinIndex, hosts_of: hosts, extenders_of: extenders)
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

    # felixefelip/rbs_infer#221. One annotation per module cannot answer a
    # question whose answer varies by method, and it has to: the same narrowing
    # types the ARGUMENT such a method passes, so the body has to see it too or
    # the two disagree.
    describe "per-def self (defs)" do
      TWO_EXTENDERS = <<~RUBY
        class Wrap
          module Foo
            def stamp(value)
              value
            end

            def other(value)
              value
            end
          end
        end
      RUBY

      # Narrows `stamp` and declines on anything else, which is what
      # `InvokerSelfTypes` does for a method nobody calls.
      def narrower_answering(answers, paths: {})
        double(:invoker_self_types).tap do |narrower|
          allow(narrower).to receive(:narrow) do |method_name:, declared:|
            answers.fetch(method_name, declared)
          end
          allow(narrower).to receive(:paths) do |method_name:, declared:|
            paths[method_name]
          end
        end
      end

      def entry_with(narrower)
        described_class.entry_for(
          path: "app/models/wrap.rb",
          module_name: "Wrap::Foo",
          source: TWO_EXTENDERS,
          mixin_index: index_answering([], extenders: ["Wrap::Bar", "Wrap::Baz"]),
          invoker_self_types: narrower
        )
      end

      it "records only the methods whose self is narrower than the module's" do
        entry = entry_with(narrower_answering({ "stamp" => "singleton(Wrap::Bar)" }))

        expect(entry["annotations"])
          .to eq(["# @type instance: (singleton(Wrap::Bar)) | (singleton(Wrap::Baz))"])
        expect(entry["defs"]).to eq("stamp" => "singleton(Wrap::Bar)")
      end

      # felixefelip/steep#141's placement feeds this straight into
      # `AnnotationParser`, which re-reads the parsed node's own location and
      # demands it be byte-for-byte the string given. RBS drops a redundant
      # outer parenthesis from that location, so `(A | B)` — which RBS itself
      # reads happily — is `Ruby::AnnotationSyntaxError` in the ANNOTATED file.
      # Two invoking hosts is what first produces a union here.
      it "writes the union in the one spelling an annotation accepts" do
        entry = entry_with(
          narrower_answering({ "stamp" => "(singleton(Wrap::Bar) | singleton(Wrap::Other))" })
        )

        expect(entry["defs"]).to eq("stamp" => "singleton(Wrap::Bar) | singleton(Wrap::Other)")
      end

      it "omits a self type RBS cannot read at all" do
        expect(entry_with(narrower_answering({ "stamp" => "not a type (" }))).not_to have_key("defs")
      end

      # felixefelip/steep#143. The per-method answer says what `self` may be
      # anywhere in the method; this says which one goes with which argument, so
      # a call whose receiver is that argument can be checked one branch at a
      # time instead of against all of them at once.
      it "states which self goes with which argument" do
        narrower = narrower_answering(
          {},
          paths: {
            "stamp" => [
              [{ 0 => "singleton(Wrap::Baz)" }, "singleton(Wrap::Bar)"],
              [{ 0 => "singleton(Wrap::Other)" }, "singleton(Wrap::OtherHost)"]
            ]
          }
        )

        expect(entry_with(narrower)["paths"]).to eq(
          "stamp" => [
            { "when" => { "value" => "singleton(Wrap::Baz)" }, "self" => "singleton(Wrap::Bar)" },
            { "when" => { "value" => "singleton(Wrap::Other)" }, "self" => "singleton(Wrap::OtherHost)" }
          ]
        )
      end

      it "omits the key when there is nothing to say" do
        expect(entry_with(narrower_answering({}))).not_to have_key("paths")
      end

      # An argument position the method has no parameter for cannot be what
      # reached it, so the whole method is left without paths rather than with
      # a partial one.
      it "omits the method when an argument names no parameter" do
        narrower = narrower_answering(
          {},
          paths: {
            "stamp" => [
              [{ 0 => "singleton(Wrap::Baz)" }, "singleton(Wrap::Bar)"],
              [{ 3 => "singleton(Wrap::Other)" }, "singleton(Wrap::OtherHost)"]
            ]
          }
        )

        expect(entry_with(narrower)).not_to have_key("paths")
      end

      it "omits the key entirely when nothing narrows" do
        expect(entry_with(narrower_answering({}))).not_to have_key("defs")
      end

      # The plugin path (`self_type_entries`) has no narrower to pass, and the
      # in-process pipeline does its own narrowing at read time anyway.
      it "omits the key when no narrower is given" do
        expect(entry_with(nil)).not_to have_key("defs")
      end

      # `def self.x`'s self is the module object — no invoker narrows it, and
      # Steep's placement skips it for the same reason.
      it "does not ask about a singleton method" do
        narrower = narrower_answering({ "stamp" => "singleton(Wrap::Bar)" })
        entry = described_class.entry_for(
          path: "app/models/wrap.rb",
          module_name: "Wrap::Foo",
          source: "class Wrap\n  module Foo\n    def self.stamp(v)\n      v\n    end\n  end\nend\n",
          mixin_index: index_answering([], extenders: ["Wrap::Bar", "Wrap::Baz"]),
          invoker_self_types: narrower
        )

        expect(entry).not_to have_key("defs")
      end
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
    def index_answering(hosts, extenders: [])
      instance_double(RbsInfer::Project::MixinIndex, hosts_of: hosts, extenders_of: extenders)
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

    # An extended module's instance method runs on the extender's CLASS OBJECT,
    # so its `self` is `singleton(Bar)` — no intersection with the module, since
    # the RBS reopen already writes `extend ::Foo` onto that singleton.
    it "answers with the extender's singleton when the module is extended" do
      entry = described_class.entry_for(
        path: "app/models/example23.rb",
        module_name: "Example23::Foo",
        source: PLAIN_SRC,
        mixin_index: index_answering([], extenders: ["Example23::Bar"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: singleton(Example23::Bar)"])
    end

    # Both routes are honest members of one union: `self` is an instance of an
    # includer or the class object of an extender, one at a time.
    it "unions include hosts with extenders" do
      entry = described_class.entry_for(
        path: "app/models/foo.rb",
        module_name: "Foo",
        source: PLAIN_SRC,
        mixin_index: index_answering(["Card"], extenders: %w[Bar Baz])
      )

      expect(entry["annotations"])
        .to eq(["# @type instance: (Card & Foo) | (singleton(Bar)) | (singleton(Baz))"])
    end

    # The convention answers "which class includes this helper". A module the
    # sources show being EXTENDED has already been answered by the code, so the
    # guess must not be added beside it.
    it "does not fall back to the convention for an extended module" do
      entry = described_class.entry_for(
        path: "app/helpers/posts_helper.rb",
        module_name: "PostsHelper",
        source: PLAIN_SRC,
        mixin_index: index_answering([], extenders: ["ERBPostsIndex"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: singleton(ERBPostsIndex)"])
    end

    # A concern is INCLUDED — that is what `ActiveSupport::Concern` is for — and
    # the `self` of a module's singleton methods when the module is extended
    # would be `singleton(singleton(Bar))`, which RBS cannot spell.
    it "omits the singleton annotation when only extenders answer" do
      entry = described_class.entry_for(
        path: "app/models/foo.rb",
        module_name: "Foo",
        source: CONCERN_SRC,
        mixin_index: index_answering([], extenders: ["Bar"])
      )

      expect(entry["annotations"]).to eq(["# @type instance: singleton(Bar)"])
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
