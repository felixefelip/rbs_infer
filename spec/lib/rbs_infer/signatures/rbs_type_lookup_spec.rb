require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Signatures::RbsTypeLookup do
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

      expect(info).to be_a(RbsInfer::Signatures::RbsClassInfo)
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

      expect(info).to be_a(RbsInfer::Signatures::RbsClassInfo)
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

  # Run-wide caches shared across instances (felixefelip/rbs_infer#47). Each
  # example runs in its own tmpdir (a distinct Dir.pwd), so the pwd-scoped
  # cache is naturally isolated; reset! is belt-and-suspenders.
  describe "run-wide sig file/glob caches" do
    around do |ex|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
    end
    before { described_class.reset! }

    def write_rbs(path, content, mtime: nil)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      File.utime(File.atime(path), mtime, path) if mtime
    end

    describe ".file_entry" do
      it "parses a file once and serves the same entry from cache" do
        write_rbs("sig/x.rbs", "class X\n  def a: () -> Integer\nend\n")

        first = described_class.file_entry("sig/x.rbs")
        second = described_class.file_entry("sig/x.rbs")

        expect(second).to be(first) # cache hit → not re-parsed
        expect(first[:index].keys).to include("X")
        expect(first[:content]).to include("def a")
      end

      it "re-parses when the file's mtime changes (stabilization rewrite)" do
        write_rbs("sig/x.rbs", "class X\nend\n", mtime: Time.at(1_000_000))
        first = described_class.file_entry("sig/x.rbs")

        write_rbs("sig/x.rbs", "class X\n  def a: () -> Integer\nend\n", mtime: Time.at(2_000_000))
        second = described_class.file_entry("sig/x.rbs")

        expect(second).not_to be(first)
        expect(second[:content]).to include("def a")
        expect(second[:index]["X"]).not_to be_nil
      end

      it "returns an empty entry for a missing file" do
        entry = described_class.file_entry("sig/missing.rbs")

        expect(entry[:declarations]).to eq([])
        expect(entry[:content]).to eq("")
        expect(entry[:index]).to eq({})
      end
    end

    describe ".glob and .reset!" do
      it "caches the glob and only sees new files after reset!" do
        write_rbs("sig/a.rbs", "class A\nend\n")
        expect(described_class.glob("sig/**/*.rbs")).to eq(["sig/a.rbs"])

        write_rbs("sig/b.rbs", "class B\nend\n")
        expect(described_class.glob("sig/**/*.rbs")).to eq(["sig/a.rbs"]) # still cached

        described_class.reset!
        expect(described_class.glob("sig/**/*.rbs")).to match_array(["sig/a.rbs", "sig/b.rbs"])
      end
    end

    it "uses a fresh cache under a different working directory (no reset! needed)" do
      write_rbs("sig/a.rbs", "class A\nend\n")
      expect(described_class.glob("sig/**/*.rbs")).to eq(["sig/a.rbs"])

      Dir.mktmpdir do |other|
        Dir.chdir(other) do
          FileUtils.mkdir_p("sig")
          File.write("sig/c.rbs", "class C\nend\n")
          expect(described_class.glob("sig/**/*.rbs")).to eq(["sig/c.rbs"])
        end
      end
    end
  end
end
