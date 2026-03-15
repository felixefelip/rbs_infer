require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Analyzer::TypeMerger do
  let(:merger) { described_class.new(target_file: nil) }

  it "prioriza tipos resolvidos sobre untyped" do
    usages = [
      { "nome" => "String", "email" => "untyped" },
      { "nome" => "String", "email" => "String" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["nome"]).to eq("String")
    expect(result["email"]).to eq("String")
  end

  it "gera union type quando há tipos diferentes" do
    usages = [
      { "value" => "String" },
      { "value" => "Integer" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["value"]).to eq("(String | Integer)")
  end

  it "normaliza :: prefix e deduplica" do
    usages = [
      { "cpf" => "::Shared::Cpf" },
      { "cpf" => "Shared::Cpf" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["cpf"]).to eq("Shared::Cpf")
  end
end
