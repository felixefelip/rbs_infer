# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
# The accessor bodies are sliced from the installed gem, so the gem has to be
# loaded for there to be anything to slice.
require "action_text"
require "rbs_infer/extensions/rails/action_text/runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::ActionText::RuntimeGenerator do
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

  def build(files)
    in_app(files) { |dir| described_class.new(app_dir: dir).build }
  end

  def source_for(files, filename)
    build(files).find { |entry| entry.filename == filename }&.source
  end

  # The reopen without the header, for assertions about what the pseudo-code
  # DOES NOT say — the header explains the omissions and names them.
  def reopen_in(files, filename)
    source_for(files, filename)[/^class .*/m]
  end

  # A method, not a constant: a constant assigned inside `RSpec.describe` lands
  # on Object, and the AR-runtime generator's spec already has one by this name
  # there — whichever file loaded last won, and this one silently tested that
  # one's fixture.
  def post_model
    <<~RUBY
      class Post < ApplicationRecord
        has_rich_text :content
      end
    RUBY
  end

  describe "the accessors the macro defines" do
    it "emits the reader, the predicate and the writer" do
      source = source_for({ "app/models/post.rb" => post_model }, "post.rb")

      expect(source).to include("class Post\n")
      expect(source).to include("  def content\n    rich_text_content || build_rich_text_content\n  end\n")
      expect(source).to include("  def content?\n    rich_text_content.present?\n  end\n")
      expect(source).to include("  def content=(body)\n    self.content.body = body\n  end\n")
    end

    # The whole point of the pseudo-code: `content` gets its type from
    # `rich_text_content || build_rich_text_content`, which rbs_rails types.
    # A generator that wrote `::ActionText::RichText` here would be a
    # hand-written sidecar with extra steps.
    it "states no type" do
      reopen = reopen_in({ "app/models/post.rb" => post_model }, "post.rb")

      expect(reopen).not_to match(/^\s*#:/)
      expect(reopen).not_to include("@rbs")
      expect(reopen).not_to include("ActionText::RichText")
    end

    # `has_one :rich_text_content` and the two scopes are REFLECTIONS, which
    # rbs_rails reflects at runtime and declares. Emitting them here would be a
    # second declaration of the same methods.
    it "leaves the has_one and the scopes to rbs_rails" do
      reopen = reopen_in({ "app/models/post.rb" => post_model }, "post.rb")

      expect(reopen).not_to include("has_one")
      expect(reopen).not_to include("with_rich_text_content")
      expect(reopen).not_to include("def rich_text_content")
    end
  end

  # The bodies are not written by this generator — they are read out of the
  # heredoc `has_rich_text` itself `class_eval`s. This is what makes the
  # `store_if_blank:` writer work without the generator knowing the option
  # exists, and what makes a future Rails rewrite land here on its own.
  describe "slicing the bodies from the installed gem" do
    it "matches the gem's own source for the attribute" do
      source = source_for({ "app/models/post.rb" => post_model }, "post.rb")
      gem_source = File.read(
        ActionText::Attribute::ClassMethods.instance_method(:has_rich_text).source_location.first
      )

      # Not a substring check on the heredoc (it interpolates); the shape the
      # gem writes, with the name filled in.
      expect(gem_source).to include("rich_text_#{'#{name}'} || build_rich_text_#{'#{name}'}")
      expect(source).to include("rich_text_content || build_rich_text_content")
    end

    # Rails 8.1 added `store_if_blank:` and a SECOND writer body behind it. The
    # generator picks the branch by reading the macro's own `if`, so nothing
    # here had to be taught what the option means.
    it "follows the macro's own branch for `store_if_blank: false`" do
      source = source_for({
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            has_rich_text :content, store_if_blank: false
          end
        RUBY
      }, "post.rb")

      # Only meaningful on a Rails that has the option; on one that does not,
      # the unconditional writer is still correct.
      if ActionText::Attribute::ClassMethods.instance_method(:has_rich_text).parameters.include?(%i[key store_if_blank])
        expect(source).to include("if body.present?")
        expect(source).to include("mark_for_destruction")
      else
        expect(source).to include("self.content.body = body")
      end
    end

    it "takes the unconditional writer by default" do
      source = source_for({ "app/models/post.rb" => post_model }, "post.rb")

      expect(source).to include("  def content=(body)\n    self.content.body = body\n  end\n")
      expect(source).not_to include("mark_for_destruction")
    end
  end

  describe "where the macro is written" do
    it "accepts a string name as Rails does" do
      source = source_for({
        "app/models/post.rb" => "class Post < ApplicationRecord\n  has_rich_text \"content\"\nend\n"
      }, "post.rb")

      expect(source).to include("def content\n")
    end

    it "reopens the qualified name of a nested class" do
      source = source_for({
        "app/models/blog/entry.rb" => <<~RUBY
          module Blog
            class Entry < ApplicationRecord
              has_rich_text :summary
            end
          end
        RUBY
      }, "blog_entry.rb")

      expect(source).to include("class Blog::Entry\n")
      expect(source).to include("def summary\n")
    end

    # `Post.rich_text_association_names` includes an attribute a concern
    # declared; reading `post.rb` alone sees no macro at all.
    it "splices a concern's `included do` into the includer" do
      source = source_for({
        "app/models/post.rb" => "class Post < ApplicationRecord\n  include Describable\nend\n",
        "app/models/concerns/describable.rb" => <<~RUBY
          module Describable
            extend ActiveSupport::Concern

            included do
              has_rich_text :description
            end
          end
        RUBY
      }, "post.rb")

      expect(source).to include("class Post\n")
      expect(source).to include("def description\n    rich_text_description || build_rich_text_description")
    end

    it "emits nothing for the concern itself" do
      files = build(
        "app/models/post.rb" => "class Post < ApplicationRecord\n  include Describable\nend\n",
        "app/models/concerns/describable.rb" => <<~RUBY
          module Describable
            extend ActiveSupport::Concern

            included do
              has_rich_text :description
            end
          end
        RUBY
      )

      expect(files.map(&:filename)).to eq(["post.rb"])
    end

    # Rails redefines the methods, so the later declaration replaces the
    # earlier one. Two accessor sets under one name would be a duplicate
    # definition in the reopen.
    it "emits one accessor set when the class redeclares a concern's attribute" do
      source = source_for({
        "app/models/post.rb" => <<~RUBY,
          class Post < ApplicationRecord
            include Describable
            has_rich_text :description
          end
        RUBY
        "app/models/concerns/describable.rb" => <<~RUBY
          module Describable
            extend ActiveSupport::Concern

            included do
              has_rich_text :description, store_if_blank: false
            end
          end
        RUBY
      }, "post.rb")

      expect(source.scan("def description\n").size).to eq(1)
      expect(source).not_to include("mark_for_destruction")
    end

    it "merges reopens of the same class across files" do
      source = source_for({
        "app/models/post.rb" => post_model,
        "app/models/post_extra.rb" => "class Post\n  has_rich_text :summary\nend\n"
      }, "post.rb")

      expect(source).to include("def content\n")
      expect(source).to include("def summary\n")
    end

    it "contributes nothing for an include it cannot see" do
      files = build("app/models/post.rb" => "class Post < ApplicationRecord\n  include Elsewhere::Thing\nend\n")

      expect(files).to be_empty
    end
  end

  describe "emitting nothing" do
    it "is empty when no model declares the macro" do
      expect(build("app/models/post.rb" => "class Post < ApplicationRecord\nend\n")).to be_empty
    end

    it "does not fire on a mere mention of the macro" do
      expect(build("app/models/post.rb" => "# has_rich_text is not used here\nclass Post; end\n")).to be_empty
    end

    # A removed `has_rich_text` must not leave a reopen behind defining a
    # method the model no longer has.
    it "drops a stale sidecar directory" do
      in_app("app/models/post.rb" => "class Post < ApplicationRecord\nend\n") do |app_dir|
        dir = File.join(app_dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "post.rb"), "class Post\n  def content; end\nend\n")

        described_class.new(app_dir: app_dir).generate

        expect(Dir.exist?(dir)).to be(false)
      end
    end
  end

  describe "#generate" do
    it "writes one file per model into the sidecar dir" do
      in_app("app/models/post.rb" => post_model) do |app_dir|
        dir = described_class.new(app_dir: app_dir).generate

        expect(dir).to eq(File.join(app_dir, described_class::SIDECAR_DIR))
        expect(File.read(File.join(dir, "post.rb"))).to include("def content\n")
      end
    end

    # `sig/**/*.rb` is how the analyzer and the Steep fork pick these up, and
    # `**` skips hidden directories — a dot-prefixed dir would be invisible.
    it "writes to a directory Steep's source glob can see" do
      expect(described_class::SIDECAR_DIR).to eq("sig/generated/steep_actiontext_runtime")
      expect(described_class::SIDECAR_DIR).not_to include("/.")
    end
  end
end
