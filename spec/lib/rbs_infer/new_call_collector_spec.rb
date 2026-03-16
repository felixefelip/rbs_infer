require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Analyzer::NewCallCollector do
  def collect_usages(source, target_class:, method_return_types: {}, local_var_types: {})
    result = Prism.parse(source)
    visitor = described_class.new(
      target_class: target_class,
      method_return_types: method_return_types,
      local_var_types: local_var_types
    )
    result.value.accept(visitor)
    visitor.usages
  end

  it "coleta kwargs de chamadas .new com literais" do
    source = <<~RUBY
      Foo.new(nome: "teste", idade: 42)
    RUBY

    usages = collect_usages(source, target_class: "Foo")
    expect(usages.size).to eq(1)
    expect(usages.first["nome"]).to eq("String")
    expect(usages.first["idade"]).to eq("Integer")
  end

  it "resolve variáveis locais atribuídas via method call" do
    source = <<~RUBY
      def test
        dto = build_dto
        Foo.new(data: dto)
      end
    RUBY

    usages = collect_usages(source,
      target_class: "Foo",
      method_return_types: { "build_dto" => "MyDto" })
    expect(usages.first["data"]).to eq("MyDto")
  end

  it "resolve variáveis locais atribuídas via Klass.new" do
    source = <<~RUBY
      def test
        client = Client::Entity.new(name: "x")
        Enroll.new(client: client)
      end
    RUBY

    usages = collect_usages(source, target_class: "Enroll")
    expect(usages.first["client"]).to eq("Client::Entity")
  end

  it "resolve class method via resolver como tipo da variável local" do
    source = <<~RUBY
      def test
        record = Record.find_by!(email: "x")
        Target.new(record: record)
      end
    RUBY

    resolver = double("MethodTypeResolver")
    allow(resolver).to receive(:resolve_class_method) do |cls, meth|
      (cls == "Record" && meth == "find_by!") ? "Record" : nil
    end
    allow(resolver).to receive(:resolve_init_param_types).and_return({})

    result = Prism.parse(source)
    visitor = described_class.new(
      target_class: "Target",
      method_return_types: {},
      local_var_types: {},
      method_type_resolver: resolver
    )
    result.value.accept(visitor)
    usages = visitor.usages
    expect(usages.first["record"]).to eq("Record")
  end

  it "match relativo: Email == Academico::Aluno::Email" do
    source = <<~RUBY
      Email.new(endereco: "test@email.com")
    RUBY

    usages = collect_usages(source, target_class: "Academico::Aluno::Email")
    expect(usages.size).to eq(1)
    expect(usages.first["endereco"]).to eq("String")
  end

  it "não faz match parcial incorreto" do
    source = <<~RUBY
      SuperEmail.new(endereco: "test")
    RUBY

    usages = collect_usages(source, target_class: "Academico::Aluno::Email")
    expect(usages).to be_empty
  end

  it "resolve implicit hash values" do
    source = <<~RUBY
      def process
        nome = build_nome
        Foo.new(nome:)
      end
    RUBY

    usages = collect_usages(source,
      target_class: "Foo",
      method_return_types: { "build_nome" => "String" })
    expect(usages.first["nome"]).to eq("String")
  end
end
