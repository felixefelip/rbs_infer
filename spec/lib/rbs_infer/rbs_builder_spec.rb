require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Analyzer::RbsBuilder do
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
end
