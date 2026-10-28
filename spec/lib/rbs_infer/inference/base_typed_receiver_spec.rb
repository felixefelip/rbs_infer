# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a call site whose receiver is typed as the target's superclass" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end

  before do
    RbsInfer::Signatures::RbsTypeLookup.reset!
    RbsInfer::Project::Corpus.reset!
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def shapes(pick: "Shape", call: "pick.area(2)")
    write("app/measurable.rb", "module Measurable\n  def area(scale) = scale\nend\n")
    write("app/shape.rb", "class Shape\n  include Measurable\n  def self.build(size) = new\nend\n")
    write("app/circle.rb", <<~RUBY)
      class Circle < Shape
        def self.build(size) = new
        def area(scale) = scale * 3
      end
    RUBY
    write("app/square.rb", "class Square < Shape\nend\n")
    write("app/caller.rb", "class Caller\n  def run = #{call}\nend\n")
    write("sig/generated/shapes.rbs", <<~RBS)
      module Measurable
        def area: (untyped scale) -> untyped
      end
      class Shape
        include Measurable
        def self.build: (untyped size) -> instance
      end
      class Circle < Shape
        def self.build: (untyped size) -> instance
        def area: (untyped scale) -> untyped
      end
      class Square < Shape
      end
      class Caller
        def pick: () -> #{pick}
      end
    RBS
  end

  def param_of(name, method_name)
    rbs_of(name)[/def #{Regexp.escape(method_name)}: \(.*?\)/]
  end

  def rbs_of(name)
    RbsInfer::Analyzer.new(target_class: name, target_file: "app/#{name.downcase}.rb", source_files: Dir["app/*.rb"])
                      .generate_rbs
  end

  it "types a subclass's override from the call" do
    shapes

    expect(param_of("Circle", "area")).to eq("def area: (2 scale)")
  end

  it "types the override from a receiver typed as a module the target includes" do
    shapes(pick: "Measurable")

    expect(param_of("Circle", "area")).to eq("def area: (2 scale)")
  end

  it "types a singleton override from a receiver typed as the superclass's singleton" do
    shapes(pick: "singleton(Shape)", call: "pick.build(4)")

    expect(param_of("Circle", "self.build")).to eq("def self.build: (4 size)")
  end

  it "leaves out an override a sibling's receiver cannot reach" do
    shapes(pick: "Square")

    expect(param_of("Circle", "area")).to eq("def area: (untyped scale)")
  end
end
