# frozen_string_literal: true

RSpec.describe RbsInfer::Signatures::DeclaredSuperclass do
  let(:resolver) { RbsInfer::Signatures::RbsDefinitionResolver.new }

  def written(target_class, superclass_name, with: resolver)
    described_class.written(target_class, superclass_name, with)
  end

  it "writes the superclass a generic class is declared with, in its declaration's type variables" do
    expect(written("Enumerator::Lazy", "Enumerator")).to eq(superclass_name: "::Enumerator", superclass_args: "[E, R]")
  end

  it "keeps the source's spelling where it names the declared superclass" do
    expect(written("Integer", "Numeric")).to eq(superclass_name: "Numeric", superclass_args: "")
  end

  it "writes the source's superclass for a class the environment does not declare" do
    expect(written("Totally::Unknown", "Array")).to eq(superclass_name: "Array", superclass_args: "[untyped]")
  end

  it "keeps an alias the source writes for the declared superclass" do
    _, _, decls = RBS::Parser.parse_signature(<<~RBS)
      module Example103
        class Store < Example103::MriBackend
        end

        class Implementation = Example103::MriBackend
      end
    RBS
    store, implementation = decls.first.members
    entries = {
      "Example103::Store" => RBS::Environment::ClassEntry.new(store.name) << [nil, store],
      "Example103::Implementation" =>
        RBS::Environment::ClassAliasEntry.new(name: implementation.new_name, decl: implementation, context: nil)
    }
    aliased = instance_double(RbsInfer::Signatures::RbsDefinitionResolver, type_param_string: "")
    allow(aliased).to receive(:declaration) { |name| entries[name] }

    expect(written("Example103::Store", "Implementation", with: aliased))
      .to eq(superclass_name: "Implementation", superclass_args: "")
  end

  it "writes none where the source names none" do
    expect(written("Enumerator::Lazy", nil)).to eq(superclass_name: nil, superclass_args: "")
  end
end
