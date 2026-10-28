# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Inference::InheritedSelfTypes do
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

  def animals(dog: "def speak(greeting) = greeting", greet: false)
    write("app/animal.rb", <<~RUBY)
      class Animal
        def introduce
          speak("hello")
        end
      #{"  def greet = introduce" if greet}
      end
    RUBY
    write("app/dog.rb", "class Dog < Animal\n  #{dog}\nend\n")
    write("app/cat.rb", "class Cat < Animal\n  def speak(greeting) = greeting\nend\n")
    write("sig/generated/animals.rbs", <<~RBS)
      class Animal
        def introduce: () -> untyped
        def greet: () -> untyped
      end
      class Dog < Animal
        def speak: (untyped greeting) -> untyped
      end
      class Cat < Animal
        def speak: (untyped greeting) -> untyped
      end
      class Caller
        def run: (untyped other) -> untyped
      end
    RBS
  end

  def caller_source(body)
    write("app/caller.rb", "class Caller\n  def run(other)\n    #{body}\n  end\nend\n")
  end

  def narrow(method_name = "introduce")
    files = Dir["app/*.rb"]
    described_class.new(
      source_index: RbsInfer::Project::SourceIndex.new(files),
      parse_cache: RbsInfer::Project::ParseCache.new,
      steep_bridge: RbsInfer::Signatures::SteepBridge.new(
        literal_method_registry: Steep::Project::LiteralMethodRegistry.from_paths(files),
        constructor_bindings: Steep::Project::ConstructorBindingRegistry.from_paths(files)
      )
    ).narrow("Animal", method_name)
  end

  it "narrows to the subclasses the method is invoked on" do
    animals
    caller_source("Dog.new.introduce\n    Cat.new.introduce")

    expect(narrow).to eq("Cat | Dog")
  end

  it "keeps the class when the method is invoked on the class itself" do
    animals
    caller_source("Dog.new.introduce\n    Animal.new.introduce")

    expect(narrow).to be_nil
  end

  it "leaves out a subclass that overrides the method" do
    animals(dog: "def speak(greeting) = greeting\n  def introduce = :own")
    caller_source("Dog.new.introduce\n    Cat.new.introduce")

    expect(narrow).to eq("Cat")
  end

  it "declines when a receiver's type is not known" do
    animals
    caller_source("other.introduce\n    Cat.new.introduce")

    expect(narrow).to be_nil
  end

  it "declines when the method is named as a symbol" do
    animals
    caller_source("Dog.new.send(:introduce)\n    Cat.new.introduce")

    expect(narrow).to be_nil
  end

  it "takes the self of the inherited method a bare call is written in" do
    animals(greet: true)
    caller_source("Dog.new.greet")

    expect(narrow).to eq("Dog")
  end

  it "keeps the class for a bare call in a method nothing invokes" do
    animals(greet: true)
    caller_source("Dog.new.introduce")

    expect(narrow).to be_nil
  end

  it "reads a subclass's super as an invocation on that subclass" do
    animals(dog: "def speak(greeting) = greeting\n  def introduce = super")
    write("sig/generated/dog_introduce.rbs", "class Dog < Animal\n  def introduce: () -> untyped\nend\n")
    caller_source("Dog.new.introduce\n    Cat.new.introduce")

    expect(narrow).to eq("Cat | Dog")
  end

  it "types a subclass's method from the bare call an inherited method makes" do
    animals
    caller_source("Dog.new.introduce")

    rbs = RbsInfer::Analyzer.new(target_class: "Dog", target_file: "app/dog.rb", source_files: Dir["app/*.rb"])
                            .generate_rbs

    expect(rbs[/def speak: \(.*?\)/]).to eq('def speak: ("hello" greeting)')
  end
end
