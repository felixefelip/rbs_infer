require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/module_self_type_generator"
require "rbs_infer/extensions/rails/active_record/runtime_generator"
require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe RbsInfer::Extensions::Rails::ModuleSelfTypeGenerator do
  # A Steepfile, because the file list is now exactly what the project tells
  # Steep to check (#165) — and because that is what a real app has.
  STEEPFILE = <<~RUBY
    target :app do
      check "app"
      check "sig/**/*.rb"
      signature "sig"
    end
  RUBY

  # The transcribed `ActiveSupport::Concern`, which every app has on disk once
  # the AR-runtime sidecar has run. `class_methods do` is read through it — the
  # DSL is a method with a body now, not a name the generator knows
  # (felixefelip/rbs_infer#268) — so an app without it resolves nothing, exactly
  # as a real one would not.
  CONCERN = RbsInfer::Extensions::Rails::ActiveRecord::Runtime::ConcernPseudoCode::SOURCE

  def in_app(files)
    Dir.mktmpdir do |dir|
      files = { "Steepfile" => STEEPFILE,
                "sig/generated/steep_ar_runtime/active_support/concern.rb" => CONCERN }.merge(files)
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
        "module Search::Record::SQLite\n  extend ActiveSupport::Concern\nend\n",
      # The host, because the self-type is read off the `include` (#163).
      "app/models/search/record.rb" =>
        "class Search::Record\n  include Search::Record::SQLite\nend\n"
    ) do |dir|
      out = described_class.new(app_dir: dir).generate
      table = YAML.safe_load(File.read(out))

      mod = table.fetch("app/models/search/record/sqlite.rb")["modules"].first
      expect(mod["anchor"]).to eq("SQLite")
      expect(mod["annotations"]).to include(
        "# @type instance: Search::Record & Search::Record::SQLite"
      )
      expect(mod["annotations"].join).not_to include("Sqlite")
    end
  end

  it "covers every source that declares a module with a host; skips the rest" do
    in_app(
      "app/models/post/taggable.rb"            => "module Post::Taggable\nend\n",
      "app/models/post.rb"                     => "class Post\n  include Post::Taggable\nend\n",
      "app/helpers/posts_helper.rb"            => "module PostsHelper\nend\n",
      "app/controllers/concerns/filterable.rb" => "module Filterable\n  extend ActiveSupport::Concern\nend\n",
      "lib/ignored.rb"                         => "module Ignored\nend\n"
    ) do |dir|
      table = described_class.new(app_dir: dir).build_table

      # `app/models/post.rb` declares a class nobody includes, and `lib/` is not
      # scanned at all. The transcribed Concern is covered like any other module
      # with extenders — the dummy's own sidecar carries the same entry.
      expect(table.keys).to contain_exactly(
        "app/models/post/taggable.rb",
        "app/helpers/posts_helper.rb",
        "app/controllers/concerns/filterable.rb",
        "sig/generated/steep_ar_runtime/active_support/concern.rb"
      )
      expect(table["app/helpers/posts_helper.rb"]["modules"].first["annotations"].first)
        .to include("ApplicationController & PostsHelper")
    end
  end

  # felixefelip/rbs_infer#189. `include Notifiable` inside `class User` means
  # `User::Notifiable`, so the top-level concern of the same name must not take
  # `User` for a host — the annotation would claim a type nothing inhabits.
  it "keeps a host out of the concern its own namespace shadows" do
    in_app(
      "app/models/concerns/notifiable.rb" =>
        "module Notifiable\n  extend ActiveSupport::Concern\nend\n",
      "app/models/user/notifiable.rb" =>
        "module User::Notifiable\n  extend ActiveSupport::Concern\nend\n",
      "app/models/user.rb"  => "class User\n  include Notifiable\nend\n",
      "app/models/event.rb" => "class Event\n  include Notifiable\nend\n"
    ) do |dir|
      table = described_class.new(app_dir: dir).build_table

      expect(table["app/models/concerns/notifiable.rb"]["modules"].first["annotations"])
        .to eq(["# @type self: singleton(Event) & singleton(Notifiable)",
                "# @type instance: Event & Notifiable"])
      expect(table["app/models/user/notifiable.rb"]["modules"].first["annotations"])
        .to eq(["# @type self: singleton(User) & singleton(User::Notifiable)",
                "# @type instance: User & User::Notifiable"])
    end
  end

  it "adds a `blocks` @implements entry for a concern with `class_methods do`" do
    in_app(
      "app/models/post/taggable.rb" => <<~RUBY,
        module Post::Taggable
          extend ActiveSupport::Concern

          class_methods do
            def default_tag_names
              ["news"]
            end
          end
        end
      RUBY
      "app/models/post.rb" => "class Post\n  include Post::Taggable\nend\n"
    ) do |dir|
      entry = described_class.new(app_dir: dir).build_table.fetch("app/models/post/taggable.rb")

      # self-type annotations and the block @implements coexist in one entry.
      expect(entry["modules"].first["anchor"]).to eq("Taggable")
      expect(entry["blocks"]).to eq(
        [{
          "call" => "class_methods",
          "in" => "::Post::Taggable",
          "implements" => "::Post::Taggable::ClassMethods",
          "self" => "singleton(::Post) & ::Post::Taggable::ClassMethods"
        }]
      )
    end
  end

  it "produces a `blocks`-only entry when the file has no self-type annotations" do
    # A top-level concern (no namespace) gets no `@type self:` entry, but its
    # `class_methods do` must still be recorded so Steep can check it.
    in_app(
      "app/models/concerns/greetable.rb" => <<~RUBY
        module Greetable
          extend ActiveSupport::Concern

          class_methods do
            def banner; "hi"; end
          end
        end
      RUBY
    ) do |dir|
      entry = described_class.new(app_dir: dir).build_table.fetch("app/models/concerns/greetable.rb")

      expect(entry).not_to have_key("anchor")
      expect(entry["blocks"]).to eq(
        [{ "call" => "class_methods", "in" => "::Greetable", "implements" => "::Greetable::ClassMethods" }]
      )
    end
  end

  # The other `blocks` contributor is CORE (`class_eval` is plain Ruby), and it
  # names its target from the replay chain rather than from the file's own
  # module — so it fires in a file whose primary declaration is a plain class.
  it "adds a `blocks` @implements entry for a stored block replayed elsewhere" do
    in_app(
      "app/models/replayed.rb" => <<~RUBY
        class Replayed
          module DSL
            attr_reader :body
            def keep(&block) = @body = block
            def apply(source) = class_eval(&source.body)
          end

          module Src
            extend DSL
            keep do
              def installed; end
            end
          end

          class Target
            extend DSL
            apply(Src)
          end
        end
      RUBY
    ) do |dir|
      entry = described_class.new(app_dir: dir).build_table.fetch("app/models/replayed.rb")

      expect(entry["blocks"]).to eq(
        [{ "call" => "keep", "in" => "::Replayed::Src", "implements" => "::Replayed::Target" }]
      )
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
