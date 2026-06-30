# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/class_methods_implements"

RSpec.describe RbsInfer::Extensions::Rails::ClassMethodsImplements do
  def blocks(source, path: "app/models/post/taggable.rb", module_name: "Post::Taggable")
    described_class.blocks_for(path: path, module_name: module_name, source: source)
  end

  it "emits @implements and the includer-singleton self for a `class_methods do` block" do
    result = blocks(<<~RUBY)
      module Post::Taggable
        extend ActiveSupport::Concern

        class_methods do
          def default_tag_names
            ["news"]
          end
        end
      end
    RUBY

    expect(result).to eq(
      [{
        "call" => "class_methods",
        "implements" => "::Post::Taggable::ClassMethods",
        "self" => "singleton(::Post) & ::Post::Taggable::ClassMethods"
      }]
    )
  end

  it "omits `self` when no including class can be derived (top-level concern)" do
    result = blocks(<<~RUBY, path: "app/models/concerns/greetable.rb", module_name: "Greetable")
      module Greetable
        extend ActiveSupport::Concern

        class_methods do
          def banner; "hi"; end
        end
      end
    RUBY

    expect(result).to eq(
      [{ "call" => "class_methods", "implements" => "::Greetable::ClassMethods" }]
    )
  end

  it "returns [] when there is no class_methods block" do
    expect(blocks(<<~RUBY)).to eq([])
      module Post::Taggable
        extend ActiveSupport::Concern

        included do
        end
      end
    RUBY
  end

  it "returns [] for a `class_methods` method call with a receiver (not the DSL)" do
    expect(blocks(<<~RUBY)).to eq([])
      module Post::Taggable
        config.class_methods do
          def x; end
        end
      end
    RUBY
  end

  it "returns [] without a module name" do
    expect(blocks("class_methods do\nend\n", module_name: nil)).to eq([])
  end

  it "returns [] on unparseable source (no crash)" do
    expect(blocks("module Broken\n  class_methods do\n")).to eq([])
  end

  describe ".self_type_entry" do
    def entry(source, path: "app/models/post/taggable.rb", module_name: "Post::Taggable")
      described_class.self_type_entry(path: path, module_name: module_name, source: source)
    end

    it "anchors the includer-singleton self on the desugared ClassMethods submodule" do
      result = entry(<<~RUBY)
        module Post::Taggable
          extend ActiveSupport::Concern

          class_methods do
            def tags_ordered_by_tag_name
              joins(:tag)
            end
          end
        end
      RUBY

      expect(result).to eq(
        "anchor" => "ClassMethods",
        "annotations" => ["# @type instance: singleton(::Post) & ::Post::Taggable::ClassMethods"]
      )
    end

    it "returns nil when no including class can be derived (top-level concern)" do
      result = entry(<<~RUBY, path: "app/models/concerns/greetable.rb", module_name: "Greetable")
        module Greetable
          extend ActiveSupport::Concern

          class_methods do
            def banner; "hi"; end
          end
        end
      RUBY

      expect(result).to be_nil
    end

    it "returns nil when there is no class_methods block" do
      expect(entry("module Post::Taggable\nend\n")).to be_nil
    end
  end
end
