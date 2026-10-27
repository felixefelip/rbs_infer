# frozen_string_literal: true

require "spec_helper"

RSpec.describe RbsInfer::Signatures::ClassAlias do
  def env_for(rbs)
    env = RBS::Environment.new
    buffer = RBS::Buffer.new(name: Pathname("app.rbs"), content: rbs)
    _, directives, decls = RBS::Parser.parse_signature(buffer)
    env.add_source(RBS::Source::RBS.new(buffer, directives, decls))
    env.resolve_type_names
  end

  def resolver_for(rbs)
    env = env_for(rbs)
    Class.new do
      define_method(:declaration) do |name|
        type_name = RBS::TypeName.parse(name).absolute!
        env.class_decls[type_name] || env.class_alias_decls[type_name]
      end
    end.new
  end

  let(:resolver) do
    resolver_for(<<~RBS)
      module Engine
        class Mri
        end
        module Helpers
        end
        class Picked = Mri
      end
    RBS
  end

  describe ".signature" do
    it "declares a constant whose value is one class as an alias of it" do
      expect(described_class.signature("Implementation", "singleton(::Engine::Mri)", resolver))
        .to eq("class Implementation = ::Engine::Mri")
    end

    it "declares one whose value is a module as a module alias" do
      expect(described_class.signature("Mixin", "singleton(::Engine::Helpers)", resolver))
        .to eq("module Mixin = ::Engine::Helpers")
    end

    it "keeps any other value a constant" do
      expect(described_class.signature("Either", "(singleton(::Engine::Mri) | nil)", resolver))
        .to eq("Either: (singleton(::Engine::Mri) | nil)")
      expect(described_class.signature("Missing", "singleton(::Engine::Gone)", resolver))
        .to eq("Missing: singleton(::Engine::Gone)")
    end
  end

  describe ".superclass" do
    def superclass(name, source)
      described_class.superclass(name, tree: Prism.parse(source).value, namespace: "Engine::Store", resolver: resolver)
    end

    it "keeps a superclass the file does not write as a constant" do
      expect(superclass("Mri", "module Engine; class Store < Mri; end; end")).to eq("Mri")
    end

    it "keeps one written through a constant the environment declares as an alias" do
      expect(superclass("Picked", "module Engine; Picked = Mri; class Store < Picked; end; end")).to eq("Picked")
    end

    it "leaves out one written through a constant the environment does not declare as an alias yet" do
      source = "module Engine; Implementation = Mri; class Store < Implementation; end; end"

      expect(superclass("Implementation", source)).to be_nil
    end
  end
end
