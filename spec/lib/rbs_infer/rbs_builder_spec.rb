require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::RbsBuilder do
  describe "#has_class_methods_module?", :dummy_app do
    let(:builder) do
      described_class.new(target_class: "Foo", superclass_name: nil)
    end

    it "retorna true para módulo que contém sub-módulo ClassMethods" do
      # ActiveModel::AttributeRegistration tem ClassMethods no .gem_rbs_collection
      result = builder.send(:has_class_methods_module?, "ActiveModel::AttributeRegistration")

      expect(result).to eq(true)
    end

    it "retorna false para módulo que NÃO contém ClassMethods" do
      result = builder.send(:has_class_methods_module?, "Comparable")

      expect(result).to eq(false)
    end

    it "retorna false quando .gem_rbs_collection não tem o módulo" do
      result = builder.send(:has_class_methods_module?, "TotallyFakeModule::DoesNotExist")

      expect(result).to eq(false)
    end
  end

  describe "#build com protected" do
    let(:builder) do
      described_class.new(target_class: "Foo", superclass_name: nil)
    end

    it "não emite 'protected' no RBS (trata como public)" do
      members = [
        RbsInfer::Member.new(kind: :method, name: "pub", signature: "pub: () -> void", visibility: :public),
        RbsInfer::Member.new(kind: :method, name: "prot", signature: "prot: () -> untyped", visibility: :protected),
        RbsInfer::Member.new(kind: :method, name: "priv", signature: "priv: () -> void", visibility: :private)
      ]

      result = builder.build(members, {}, {})

      expect(result).not_to include("protected")
      expect(result).to include("def pub: () -> void")
      expect(result).to include("def prot: () -> untyped")
      expect(result).to include("private")
      expect(result).to include("def priv: () -> void")
    end

    it "gera RBS válido quando tem métodos protected" do
      members = [
        RbsInfer::Member.new(kind: :method, name: "request_range", signature: "request_range: (untyped range) -> untyped", visibility: :protected),
        RbsInfer::Member.new(kind: :method, name: "with_http", signature: "with_http: () -> untyped", visibility: :private)
      ]

      result = builder.build(members, {}, {})

      expect { RBS::Parser.parse_signature(result) }.not_to raise_error
    end
  end
end
