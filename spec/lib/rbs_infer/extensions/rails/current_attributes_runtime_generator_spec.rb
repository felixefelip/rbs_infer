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

  it "reopens a CurrentAttributes subclass with a delegating singleton setter" do
    result = build("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user, :author_name

        def user=(value)
          super(value)
          self.author_name = value&.full_name
        end
      end
    RUBY

    source = result.find { |f| f[:filename] == "current.rb" }[:source]
    expect(source).to include("class Current")
    expect(source).to include("def self.user=(value)")
    expect(source).to include("instance.user = value")
  end

  it "emits the delegation only for attributes the class overrides" do
    # `author_name` has no instance setter override, so its singleton setter
    # establishes nothing — no delegation needed.
    result = build("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user, :author_name

        def user=(value)
          super(value)
          self.author_name = value&.full_name
        end
      end
    RUBY

    source = result.find { |f| f[:filename] == "current.rb" }[:source]
    expect(source).to include("def self.user=(value)")
    expect(source).not_to include("def self.author_name=")
  end

  it "emits nothing for a subclass with no overridden setter" do
    result = build("app/models/current.rb" => <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
      end
    RUBY

    expect(result).to be_empty
  end

  it "ignores classes that are not CurrentAttributes subclasses" do
    expect(build("app/models/post.rb" => "class Post < ApplicationRecord\nend\n")).to be_empty
  end

  describe "#generate" do
    it "writes the sidecar and removes a stale one" do
      in_app("app/models/current.rb" => <<~RUBY) do |dir|
        class Current < ActiveSupport::CurrentAttributes
          attribute :user
          def user=(value)
            super(value)
            self.author_name = value&.full_name
          end
        end
      RUBY
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
