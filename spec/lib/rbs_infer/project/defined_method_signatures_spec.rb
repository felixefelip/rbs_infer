# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::DefinedMethodSignatures do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Dir.chdir(dir) do
        RbsInfer::Signatures::SteepEnvironment.reset!
        example.run
      end
    end
    RbsInfer::Signatures::SteepEnvironment.reset!
  end

  def write_file(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_sidecar(methods)
    write_file(described_class::SIDECAR, YAML.dump({ "version" => 1, "methods" => methods }))
  end

  def generate
    described_class.generate(base_dir: @dir, resolver: RbsInfer::Signatures::RbsDefinitionResolver.new)
  end

  def output
    File.read(described_class::OUTPUT)
  end

  it "declares each method the sidecar lists, in a reopening of its class" do
    write_file("sig/app/base.rbs", "class Base\nend\nmodule Store\nend\n")
    write_sidecar(
      "Base.__class_attr_pluralize" => { "params" => "()", "returns" => "untyped" },
      "Base.__class_attr_pluralize=" => { "params" => "(untyped new_value)", "returns" => "untyped" },
      "Store#fetch" => { "params" => "(?untyped key)", "returns" => "::Integer" }
    )

    expect(generate).to be_truthy
    expect(output).to end_with(<<~RBS)
      class Base
        def self.__class_attr_pluralize: () -> untyped
        def self.__class_attr_pluralize=: (untyped new_value) -> untyped
      end

      module Store
        def fetch: (?untyped key) -> ::Integer
      end
    RBS
  end

  it "reopens a generic class with its type parameters" do
    write_file("sig/app/box.rbs", "class Box[unchecked out T]\nend\n")
    write_sidecar("Box#peek" => { "params" => "()", "returns" => "untyped" })

    generate

    expect(output).to include("class Box[unchecked out T]\n  def peek: () -> untyped\nend\n")
  end

  it "leaves a method another signature declares to it" do
    write_file("sig/app/base.rbs", "class Base\n  def self.__store: () -> bool\nend\n")
    write_sidecar("Base.__store" => { "params" => "()", "returns" => "untyped" })

    generate

    expect(File).not_to exist(described_class::OUTPUT)
  end

  it "keeps declaring a method only its own previous output declares" do
    write_file("sig/app/base.rbs", "class Base\nend\n")
    write_sidecar("Base.__store" => { "params" => "()", "returns" => "untyped" })
    generate
    RbsInfer::Signatures::SteepEnvironment.reset!

    expect(generate).to be_nil
    expect(output).to include("def self.__store: () -> untyped")
  end

  it "removes its output once the sidecar lists nothing" do
    write_file("sig/app/base.rbs", "class Base\nend\n")
    write_sidecar("Base.__store" => { "params" => "()", "returns" => "untyped" })
    generate
    FileUtils.rm(described_class::SIDECAR)

    expect(generate).to be_truthy
    expect(File).not_to exist(described_class::OUTPUT)
  end
end
