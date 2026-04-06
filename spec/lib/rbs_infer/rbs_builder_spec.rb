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

  describe "#build com namespaces" do
    it "usa 'module' para namespace que é módulo (sintaxe compacta)" do
      builder = described_class.new(
        target_class: "Card::Eventable::SystemCommenter",
        superclass_name: nil,
        namespace_classes: Set.new  # Card::Eventable NÃO está no set → deve ser module
      )

      result = builder.build([], {}, {})

      expect(result).to include("module Card")
      expect(result).to include("module Eventable")
      expect(result).not_to include("class Eventable")
    end

    it "usa 'class' para namespace que é classe" do
      builder = described_class.new(
        target_class: "Card::Eventable::SystemCommenter",
        superclass_name: nil,
        namespace_classes: Set.new(["Card::Eventable"])
      )

      result = builder.build([], {}, {})

      expect(result).to include("class Eventable")
      expect(result).not_to include("module Eventable")
    end
  end

  describe "#build com qualify (include/extend ambíguos)" do
    it "prefixa include com :: quando o nome coincide com parte do namespace" do
      # Account::Storage inclui Storage::Totaled → dentro de class Account { module Storage }
      # o RBS resolveria Storage::Totaled como Account::Storage::Totaled (errado)
      members = [
        RbsInfer::Member.new(kind: :include, name: "Storage::Totaled", signature: "", visibility: :public)
      ]
      builder = described_class.new(target_class: "Account::Storage", superclass_name: nil)
      result = builder.build(members, {}, {})

      expect(result).to include("include ::Storage::Totaled")
    end

    it "prefixa superclass com :: quando o nome coincide com parte do namespace" do
      # Account::Export < Export → dentro de class Account, Export resolve como Account::Export
      builder = described_class.new(target_class: "Account::Export", superclass_name: "Export")
      result = builder.build([], {}, {})

      expect(result).to include("class Export < ::Export")
    end

    it "não prefixa include quando não há ambiguidade" do
      members = [
        RbsInfer::Member.new(kind: :include, name: "ActiveSupport::Concern", signature: "", visibility: :public)
      ]
      builder = described_class.new(target_class: "Account::Storage", superclass_name: nil)
      result = builder.build(members, {}, {})

      expect(result).to include("include ActiveSupport::Concern")
      expect(result).not_to include("::ActiveSupport")
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
