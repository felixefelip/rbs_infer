require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::TypeMerger do
  let(:merger) { described_class.new(target_file: nil, constant_resolver: fake_constant_resolver) }

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

  describe ".union_types" do
    it "unions distinct types preserving the original form" do
      expect(described_class.union_types(["String", "::MyApp::Entity"]))
        .to eq("(String | ::MyApp::Entity)")
    end

    it "emits a single type verbatim (keeps the absolute `::`)" do
      expect(described_class.union_types(["::MyApp::Entity"])).to eq("::MyApp::Entity")
    end

    it "flattens pre-existing unions instead of nesting parens" do
      expect(described_class.union_types(["(String | Symbol)", "Symbol"]))
        .to eq("(String | Symbol)")
    end

    it "does not flatten a `|` nested inside generics" do
      expect(described_class.union_types(["Array[String | Symbol]"]))
        .to eq("Array[String | Symbol]")
    end

    it "drops untyped when at least one resolved type exists" do
      expect(described_class.union_types(["untyped", "String"])).to eq("String")
    end
  end

  describe "#resolve_method_return_types_from_attrs" do
    it "não corrompe assinatura de método com bloco ao resolver return type" do
      source = <<~RUBY
        class Foo
          def wrapper(&block)
            "hello"
          end
        end
      RUBY

      result = Prism.parse(source)
      comments = result.comments
      lines = source.lines

      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: comments, lines: lines)
      result.value.accept(collector)

      member = collector.members.find { |m| m.name == "wrapper" }
      # Signature should have block: "wrapper: () ?{ (untyped) -> untyped } -> String"
      # The block's -> untyped should NOT be replaced
      expect(member.signature).to include("?{ (untyped) -> untyped } -> String")
      expect(member.signature).not_to include("-> untyped } -> String } -> String")
    end
  end
end
