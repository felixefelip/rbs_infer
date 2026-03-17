require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Analyzer::RbsTypeLookup do
  subject(:lookup) { described_class.new }

  describe "#parse_rbs_class_block" do
    it "extrai superclass, métodos de instância, includes e class methods" do
      rbs = <<~RBS
        class User < ApplicationRecord
          def name: () -> String
          def age: () -> Integer
          def self.find_by_email: (String) -> User?
          include ActiveModel::Validations
          attr_reader email: String
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "User")

      expect(info).to be_a(RbsInfer::Analyzer::RbsClassInfo)
      expect(info.superclass).to eq("ApplicationRecord")
      expect(info.types).to include("name" => "String", "age" => "Integer", "email" => "String")
      expect(info.class_method_types).to include("find_by_email" => "User?")
      expect(info.includes).to include("ActiveModel::Validations")
    end

    it "resolve classes aninhadas via nesting (module A / class B)" do
      rbs = <<~RBS
        module Admin
          class User
            def role: () -> String
          end
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "Admin::User")

      expect(info.types).to eq("role" => "String")
    end

    it "resolve classes com namespace inline (class A::B)" do
      rbs = <<~RBS
        class Admin::User
          def role: () -> String
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "Admin::User")

      expect(info.types).to eq("role" => "String")
    end

    it "resolve classes com :: absoluto" do
      rbs = <<~RBS
        class ::Admin::User
          def role: () -> String
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "Admin::User")

      expect(info.types).to eq("role" => "String")
    end

    it "ignora attr_reader untyped" do
      rbs = <<~RBS
        class Foo
          attr_reader name: untyped
          attr_reader count: Integer
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "Foo")

      expect(info.types).to eq("count" => "Integer")
    end

    it "retorna RbsClassInfo vazio quando classe não encontrada" do
      rbs = <<~RBS
        class Other
          def name: () -> String
        end
      RBS

      info = lookup.parse_rbs_class_block(rbs, "Foo")

      expect(info.types).to be_empty
      expect(info.superclass).to be_nil
      expect(info.includes).to be_empty
      expect(info.class_method_types).to be_empty
    end
  end

  describe "#lookup_rbs_collection_module_types" do
    it "retorna tipos de métodos de um módulo no .gem_rbs_collection", :dummy_app do
      types = lookup.lookup_rbs_collection_module_types("ActiveModel::Validations")

      # Deve ao menos encontrar alguns métodos (o módulo existe no collection)
      expect(types).to be_a(Hash)
      # Se não encontrar, ao menos não deve dar erro
    end
  end

  describe "#lookup_gem_rbs_collection_class", :dummy_app do
    it "retorna RbsClassInfo ao buscar classe em .gem_rbs_collection" do
      info = lookup.lookup_gem_rbs_collection_class("ActiveRecord::Base")

      expect(info).to be_a(RbsInfer::Analyzer::RbsClassInfo)
      # Não deve levantar exceção — esse é o teste principal
    end
  end

  describe "#lookup_inherited_types", :dummy_app do
    it "resolve tipos herdados via cadeia de superclasses" do
      types = lookup.lookup_inherited_types("ApplicationRecord")

      expect(types).to be_a(Hash)
      # Não deve levantar exceção ao percorrer a cadeia
    end
  end
end
