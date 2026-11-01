# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a .new whose receiver is typed as a class object" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def source
    <<~RUBY
      module R
        class Macro
          def initialize(name, ar)
            @name = name
            @ar = ar
          end
        end

        class Assoc < Macro
          def initialize(name, ar)
            super
          end
        end

        class Many < Assoc
        end

        class One < Assoc
        end

        def self.class_for(kind)
          case kind
          when :many then Many
          else One
          end
        end

        def self.create(kind, name, ar)
          class_for(kind).new(name, ar)
        end

        def self.loose(klass, name)
          klass.new(name, nil)
        end

        class Post
          def self.go = R.create(:many, :comments, self)
        end
      end
    RUBY
  end

  def initialize_signature(target, class_for:, loose: "untyped klass")
    File.write("r.rb", source)
    FileUtils.mkdir_p("sig/generated")
    File.write("sig/generated/r.rbs", <<~RBS)
      module R
        def self.class_for: (:many kind) -> #{class_for}
        def self.create: (:many kind, :comments name, singleton(R::Post) ar) -> R::Many
        def self.loose: (#{loose}, :other name) -> untyped

        class Macro
          def initialize: (untyped name, untyped ar) -> void
        end

        class Assoc < Macro
          def initialize: (untyped name, untyped ar) -> void
        end

        class Many < Assoc
        end

        class One < Assoc
        end

        class Post
          def self.go: () -> R::Many
        end
      end
    RBS
    rbs = RbsInfer::Analyzer.new(target_class: target, target_file: "r.rb", source_files: ["r.rb"]).generate_rbs
    rbs[/def initialize: .*$/]
  end

  it "is a call site of the initialize of the class it builds" do
    expect(initialize_signature("R::Assoc", class_for: "singleton(R::Assoc)"))
      .to eq("def initialize: (:comments name, singleton(R::Post) ar) -> void")
  end

  it "is a call site of the initialize the class it builds inherits" do
    expect(initialize_signature("R::Assoc", class_for: "singleton(R::Many)"))
      .to eq("def initialize: (:comments name, singleton(R::Post) ar) -> void")
  end

  it "is a call site of the initialize of every class object the receiver may be" do
    expect(initialize_signature("R::Assoc", class_for: "(singleton(R::Many) | singleton(R::One))"))
      .to eq("def initialize: (:comments name, singleton(R::Post) ar) -> void")
  end

  it "is no call site where the receiver may be anything" do
    signature = initialize_signature("R::Assoc", class_for: "singleton(R::Many)", loose: "untyped klass")

    expect(signature).not_to include(":other")
  end
end
