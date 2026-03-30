require "spec_helper"
require "rbs_infer"
require "rbs"

RSpec.describe RbsInfer::RbsParserUtil do
  describe ".class_info_from_rbs" do
    it "extrai informações de classe simples" do
      rbs = <<~RBS
        class User
          def name: () -> String
          def self.find: (Integer) -> User
          include Comparable
          attr_reader email: String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "User")

      expect(info).to be_a(RbsInfer::RbsClassInfo)
      expect(info.types).to include("name" => "String")
      expect(info.class_method_types).to include("find" => "User")
      expect(info.includes).to include("Comparable")
      expect(info.types).to include("email" => "String")
    end

    it "extrai superclass" do
      rbs = <<~RBS
        class Admin < User
          def role: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin")

      expect(info.superclass).to eq("User")
      expect(info.types).to eq("role" => "String")
    end

    it "encontra classe dentro de módulo aninhado" do
      rbs = <<~RBS
        module Admin
          class User
            def name: () -> String
          end
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("name" => "String")
    end

    it "encontra classe com namespace inline" do
      rbs = <<~RBS
        class Admin::User
          def name: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("name" => "String")
    end

    it "encontra módulo e seus métodos" do
      rbs = <<~RBS
        module Searchable
          def search: (String query) -> Array[self]
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Searchable")

      expect(info.types).to include("search")
    end

    it "retorna RbsClassInfo vazio quando classe não encontrada" do
      rbs = <<~RBS
        class Other
          def x: () -> void
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to be_empty
      expect(info.superclass).to be_nil
    end

    it "extrai attr_reader com tipo" do
      rbs = <<~RBS
        class Foo
          attr_reader name: String
          attr_reader count: Integer
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to include("name" => "String", "count" => "Integer")
    end

    it "ignora attr_reader untyped" do
      rbs = <<~RBS
        class Foo
          attr_reader name: untyped
          attr_reader count: Integer
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to eq("count" => "Integer")
      expect(info.types).not_to have_key("name")
    end

    it "resolve nesting profundo (3+ níveis)" do
      rbs = <<~RBS
        module A
          module B
            class C
              def x: () -> void
            end
          end
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "A::B::C")

      expect(info.types).to include("x")
    end

    it "resolve classe com :: absoluto" do
      rbs = <<~RBS
        class ::Admin::User
          def role: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("role" => "String")
    end
  end

  describe ".has_class_methods_submodule?" do
    it "retorna true quando módulo contém sub-módulo ClassMethods" do
      rbs = <<~RBS
        module Devise
          module Models
            module Authenticatable
              module ClassMethods
                def find_by_email: (String) -> Authenticatable?
              end
            end
          end
        end
      RBS

      result = described_class.has_class_methods_submodule?(rbs, "Devise::Models::Authenticatable")

      expect(result).to eq(true)
    end

    it "retorna false quando módulo NÃO contém ClassMethods" do
      rbs = <<~RBS
        module Searchable
          def search: (String) -> Array[self]
        end
      RBS

      result = described_class.has_class_methods_submodule?(rbs, "Searchable")

      expect(result).to eq(false)
    end
  end

  describe ".sanitize_rbs_content" do
    it "remove linhas com protected (não suportado pelo RBS)" do
      content = <<~RBS
        class Foo
          def public_method: () -> void

          protected

          def protected_method: () -> untyped

          private

          def private_method: () -> void
        end
      RBS

      result = described_class.sanitize_rbs_content(content)

      expect(result).not_to match(/^\s*protected\s*$/)
      expect(result).to include("private")
      expect(result).to include("def public_method")
      expect(result).to include("def protected_method")
    end
  end

  describe ".class_info_from_rbs com protected" do
    it "parseia RBS contendo protected sem erro" do
      rbs = <<~RBS
        class Foo
          def public_method: () -> String

          protected

          def protected_method: () -> Integer

          private

          def private_method: () -> void
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to include("public_method" => "String")
      expect(info.types).to include("protected_method" => "Integer")
    end
  end
end
