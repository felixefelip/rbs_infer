# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "an attr or alias another signature already declares" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def write_lib
    write("lib/lib.rb", <<~RUBY)
      class Lib
        attr_reader :name, :size
        attr_accessor :parent

        def initialize
          @name = "lib"
          @size = 1
          @parent = nil
        end

        def old_name = name
        alias new_name old_name
        alias other_name old_name

        # @rbs_infer |...
        def check! = nil
      end
    RUBY
  end

  def write_vendor
    write("sig/vendor/lib.rbs", <<~RBS)
      class Lib
        attr_reader name: untyped
        attr_reader parent: untyped
        alias new_name old_name
        alias check! old_name
      end
    RBS
  end

  def lib_rbs
    RbsInfer::Analyzer.new(target_class: "Lib", target_file: "lib/lib.rb",
                           source_files: Dir["lib/*.rb"]).generate_rbs
  end

  def builds_with_vendor?(rbs)
    write("sig/generated/lib/lib.rbs", rbs)
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname("sig"))
    env = RBS::Environment.from_loader(loader).resolve_type_names
    RBS::DefinitionBuilder.new(env: env).build_instance(RBS::TypeName.parse("::Lib"))
  end

  it "leaves the alias to that signature" do
    write_lib
    write_vendor

    rbs = lib_rbs
    expect(rbs).not_to include("alias new_name")
    expect(rbs).to include("alias other_name old_name")
  end

  it "puts each colliding attr half ahead of that signature as an overloading def" do
    write_lib
    write_vendor

    rbs = lib_rbs
    expect(rbs).to include('def name: () -> "lib" | ...')
    expect(rbs).to include('@name: "lib"')
    expect(rbs).to include("attr_reader size: 1")
    expect(rbs).to include("def parent: () -> nil | ...")
    expect(rbs).to include("attr_writer parent: nil")
    expect(rbs).not_to include("@parent:")
  end

  it "overloads a marked def over an alias that signature declares" do
    write_lib
    write_vendor

    expect(lib_rbs).to include("def check!: () -> nil | ...")
  end

  it "emits a signature the environment can build next to that one" do
    write_lib
    write_vendor

    definition = builds_with_vendor?(lib_rbs)
    expect(definition.methods[:name].method_types.map(&:to_s)).to eq(['() -> "lib"', "() -> untyped"])
  end

  it "keeps the plain attr and alias when only the previous output of the same file declares them" do
    write_lib
    write("sig/generated/lib/lib.rbs", <<~RBS)
      class Lib
        attr_reader name: "lib"
        def old_name: () -> String
        alias new_name old_name
      end
    RBS

    rbs = lib_rbs
    expect(rbs).to include('attr_reader name: "lib"')
    expect(rbs).to include("alias new_name old_name")
  end
end
