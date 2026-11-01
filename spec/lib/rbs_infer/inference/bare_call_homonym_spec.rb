# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a bare call whose name another class of the file defines" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def rbs_for(target, source, builder_rbs)
    File.write("app.rb", source)
    FileUtils.mkdir_p("sig/generated")
    File.write("sig/generated/app.rbs", <<~RBS)
      module Shop
        module Reflection
          def self.create: (untyped kind, untyped name) -> untyped

          class Single
            def kind: () -> :single
          end
        end

        class Builder
          def self.build: (Symbol name) -> untyped
          #{builder_rbs}
        end

        class Order
          def self.go: () -> untyped
        end
      end
    RBS
    RbsInfer::Analyzer.new(target_class: target, target_file: "app.rb", source_files: ["app.rb"]).generate_rbs
  end

  def source(builder_kind)
    <<~RUBY
      module Shop
        module Reflection
          def self.create(kind, name)
            kind
          end

          class Single
            def kind; :single; end
          end
        end

        class Builder
          def self.build(name)
            Reflection.create(kind, name)
          end

          #{builder_kind}
        end

        class Order
          def self.go = Builder.build(:items)
        end
      end
    RUBY
  end

  it "reads the class method its own class defines" do
    rbs = rbs_for("Shop::Reflection", source("def self.kind; :many; end"), "def self.kind: () -> :many")

    expect(rbs).to include("def self.create: (:many kind")
  end

  it "does not read an instance method another class defines" do
    rbs = rbs_for("Shop::Reflection", source("def self.kind; raise NotImplementedError; end"),
                  "def self.kind: () -> untyped")

    expect(rbs).not_to include(":single")
  end

  it "does not read an instance method its own class defines" do
    rbs = rbs_for("Shop::Reflection", source("def kind; :instance; end"), "def kind: () -> :instance")

    expect(rbs).not_to include(":instance")
  end
end
