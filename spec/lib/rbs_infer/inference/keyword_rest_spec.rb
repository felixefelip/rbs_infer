# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require_relative "../../../support/temp_file_helpers"

RSpec.describe "a keyword rest typed from its call sites" do
  include TempFileHelpers

  def rbs_for(files)
    with_temp_files(files) do |_dir, paths|
      RbsInfer::Analyzer.new(target_file: paths.first, source_files: paths).generate_rbs
    end
  end

  it "declares the keywords the call sites pass, optional where some call omits them" do
    rbs = rbs_for(
      "registry.rb" => <<~RUBY,
        class Registry
          def add(name, **options)
            options
          end
        end
      RUBY
      "app.rb" => <<~RUBY
        Registry.new.add(:a)
        Registry.new.add(:b, dependent: :destroy, as: "x")
        Registry.new.add(:c, as: "y")
      RUBY
    )

    expect(rbs).to include('def add: ((:a | :b | :c) name, ?dependent: :destroy, ?as: ("x" | "y"))')
  end

  it "requires a keyword every call passes" do
    rbs = rbs_for(
      "registry.rb" => <<~RUBY,
        class Registry
          def add(name, **options)
            options
          end
        end
      RUBY
      "app.rb" => <<~RUBY
        Registry.new.add(:a, as: "x")
        Registry.new.add(:b, as: "y")
      RUBY
    )

    expect(rbs).to include('def add: ((:a | :b) name, as: ("x" | "y"))')
  end

  it "declares no keyword rest when no call passes a keyword" do
    rbs = rbs_for(
      "registry.rb" => <<~RUBY,
        class Registry
          def add(name, **options)
            options
          end
        end
      RUBY
      "app.rb" => <<~RUBY
        Registry.new.add(:a)
      RUBY
    )

    expect(rbs).to include("def add: (:a name) ->")
  end

  it "keeps the keyword rest open when a call splats a hash into it" do
    rbs = rbs_for(
      "registry.rb" => <<~RUBY,
        class Registry
          def add(name, **options)
            options
          end
        end
      RUBY
      "app.rb" => <<~RUBY
        opts = { as: "x" }
        Registry.new.add(:a)
        Registry.new.add(:b, **opts)
      RUBY
    )

    expect(rbs).to include("**untyped options")
  end

  it "counts the calls the class makes to itself" do
    rbs = rbs_for(
      "registry.rb" => <<~RUBY
        class Registry
          def setup
            add(:a, as: "x")
          end

          private

          def add(name, **options)
            options
          end
        end
      RUBY
    )

    expect(rbs).to include('def add: (:a name, as: "x")')
  end

  it "adds the keys the class stores into the record it is given" do
    rbs = rbs_for(
      "reflection.rb" => <<~RUBY,
        class Reflection
          attr_reader :options

          def initialize(options)
            @options = options
          end

          def autosave!
            @options[:autosave] = true
          end
        end
      RUBY
      "app.rb" => <<~RUBY
        Reflection.new({ through: :taggings })
      RUBY
    )

    expect(rbs).to include("attr_reader options: { through: :taggings, ?autosave: true }")
  end
end
