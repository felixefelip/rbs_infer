require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Analyzer::IntraClassCallAnalyzer do
  def analyze(source, attr_types: {}, method_type_resolver: nil)
    result = Prism.parse(source)
    visitor = described_class.new(attr_types: attr_types, method_type_resolver: method_type_resolver)
    result.value.accept(visitor)
    visitor
  end

  it "infere tipo de kwarg via local variable = Klass.new(...)" do
    source = <<~RUBY
      class Foo
        def call
          aluno = Entity.new(nome: "test")
          publicar(aluno:)
        end

        def publicar(aluno:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["publicar"]["aluno"]).to eq("Entity")
  end

  it "infere tipo via ImplicitNode (shorthand keyword: publicar(aluno:))" do
    source = <<~RUBY
      class Foo
        def call
          aluno = ::MyApp::Entity.new(nome: "test")
          publicar(aluno:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["publicar"]["aluno"]).to eq("::MyApp::Entity")
  end

  it "ignora argumentos com tipo desconhecido" do
    source = <<~RUBY
      class Foo
        def call
          publicar(aluno: alguma_coisa)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["publicar"]).to be_empty
  end

  it "infere múltiplos kwargs na mesma chamada" do
    source = <<~RUBY
      class Foo
        def call
          aluno = Entity.new
          curso = Curso.new
          matricular(aluno:, curso:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["matricular"]["aluno"]).to eq("Entity")
    expect(visitor.inferred_param_types["matricular"]["curso"]).to eq("Curso")
  end

  context "usage-side: infere tipos de params via Klass.new(param:) no corpo" do
    let(:resolver) do
      instance_double(RbsInfer::Analyzer::MethodTypeResolver).tap do |r|
        allow(r).to receive(:resolve_all).with("Telefone").and_return({
          "ddd" => "String",
          "numero" => "String"
        })
      end
    end

    it "infere tipo de param quando forwarded via shorthand para Klass.new(param:)" do
      source = <<~RUBY
        class Foo
          def adicionar_telefone(ddd:, numero:)
            Telefone.new(ddd:, numero:)
          end
        end
      RUBY

      visitor = analyze(source, method_type_resolver: resolver)
      expect(visitor.inferred_param_types["adicionar_telefone"]["ddd"]).to eq("String")
      expect(visitor.inferred_param_types["adicionar_telefone"]["numero"]).to eq("String")
    end

    it "infere tipo via param: param explícito em Klass.new" do
      source = <<~RUBY
        class Foo
          def adicionar(codigo:)
            Telefone.new(ddd: codigo)
          end
        end
      RUBY

      resolver_local = instance_double(RbsInfer::Analyzer::MethodTypeResolver)
      allow(resolver_local).to receive(:resolve_all).with("Telefone").and_return({
        "ddd" => "String",
        "numero" => "String"
      })

      visitor = analyze(source, method_type_resolver: resolver_local)
      expect(visitor.inferred_param_types["adicionar"]["codigo"]).to eq("String")
    end

    it "não infere quando o valor não é um parâmetro do método" do
      source = <<~RUBY
        class Foo
          def adicionar(ddd:)
            local = "11"
            Telefone.new(ddd:, numero: local)
          end
        end
      RUBY

      visitor = analyze(source, method_type_resolver: resolver)
      expect(visitor.inferred_param_types["adicionar"]["ddd"]).to eq("String")
      expect(visitor.inferred_param_types["adicionar"]).not_to have_key("numero")
    end

    it "não infere sem method_type_resolver" do
      source = <<~RUBY
        class Foo
          def adicionar(ddd:)
            Telefone.new(ddd:)
          end
        end
      RUBY

      visitor = analyze(source)
      expect(visitor.inferred_param_types["adicionar"]).to be_empty
    end
  end
end
