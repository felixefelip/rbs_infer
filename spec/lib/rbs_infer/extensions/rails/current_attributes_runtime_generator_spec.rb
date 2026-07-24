# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/current_attributes_runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::CurrentAttributesRuntimeGenerator do
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

  def source_for(files, filename = "current.rb")
    build(files).find { |f| f[:filename] == filename }&.fetch(:source)
  end

  WITH_OVERRIDE = <<~RUBY
    class Current < ActiveSupport::CurrentAttributes
      attribute :user, :author_name

      def user=(value)
        super(value)
        self.author_name = value&.full_name
      end
    end
  RUBY

  it "reopens the class (no superclass), mergeable with the real source" do
    source = source_for("app/models/current.rb" => WITH_OVERRIDE)
    expect(source).to include("class Current\n")
    expect(source).not_to include("< ActiveSupport::CurrentAttributes")
  end

  it "emits instance accessors in an included GeneratedAttributeMethods module" do
    source = source_for("app/models/current.rb" => WITH_OVERRIDE)
    expect(source).to include("module GeneratedAttributeMethods")
    expect(source).to include("include GeneratedAttributeMethods")
    # the module is the `super` target for the override, so the instance
    # accessor is emitted even for the overridden attribute
    expect(source).to include("def user=(value)")
  end

  it "makes the singleton setter delegate through the typed __rbs_infer_instance helper" do
    source = source_for("app/models/current.rb" => WITH_OVERRIDE)
    expect(source).to include("def self.user=(value)")
    # Delegation routes through the memoized helper (typed as the subclass),
    # NOT the framework `instance` (typed `untyped` by gem RBS).
    expect(source).to include("__rbs_infer_instance.user = value")
    expect(source).not_to match(/(?<!__rbs_infer_)instance\.user = value/)
  end

  it "emits the memoized __rbs_infer_instance helper when a setter delegates" do
    source = source_for("app/models/current.rb" => WITH_OVERRIDE)
    # `@x ||= Klass.new` — the shape Steep infers a concrete return type for,
    # so the delegation is recognized by return type, not by the `instance` name.
    expect(source).to include("def self.__rbs_infer_instance")
    expect(source).to include("@__rbs_infer_instance ||= Current.new")
  end

  it "omits the __rbs_infer_instance helper when no setter delegates" do
    source = source_for("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def self.user=(value)
          @user = value
        end
      end
    RUBY

    expect(source).not_to include("__rbs_infer_instance")
  end

  it "skips singleton accessors the class overrides itself" do
    source = source_for("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def self.user=(value)
          @user = value
        end
      end
    RUBY

    # the class defines self.user= itself, so it is not re-emitted
    expect(source.scan("def self.user=").size).to eq(0)
    # the instance module accessor is still emitted
    expect(source).to include("def user=(value)")
  end

  it "emits set/with with the attributes as kwargs" do
    source = source_for("app/models/current.rb" => WITH_OVERRIDE)
    expect(source).to include("def self.set(user: nil, author_name: nil, &block)")
    expect(source).to include("def self.with(user: nil, author_name: nil, &block)")
  end

  it "emits initialize for a default" do
    source = source_for("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :count, default: -> { 0 }
      end
    RUBY

    expect(source).to include("def initialize")
    expect(source).to include("@count = 0")
  end

  it "ignores classes that are not CurrentAttributes subclasses" do
    expect(build("app/models/post.rb" => "class Post < ApplicationRecord\nend\n")).to be_empty
  end

  it "emits nothing for a subclass with no attributes" do
    expect(build("app/models/current.rb" => "class Current < ActiveSupport::CurrentAttributes\nend\n")).to be_empty
  end

  describe "#generate" do
    it "writes the sidecar and removes a stale one" do
      in_app("app/models/current.rb" => WITH_OVERRIDE) do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR, "gone.rb")
        FileUtils.mkdir_p(File.dirname(stale))
        File.write(stale, "# stale")

        described_class.new(app_dir: dir).generate

        expect(File).to exist(File.join(dir, described_class::SIDECAR_DIR, "current.rb"))
        expect(File).not_to exist(stale)
      end
    end
  end
end
