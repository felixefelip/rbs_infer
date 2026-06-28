require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::InitializeBodyAnalyzer do
  def analyze(source, constant_resolver: fake_constant_resolver)
    result = Prism.parse(source)
    visitor = described_class.new(constant_resolver: constant_resolver)
    result.value.accept(visitor)
    visitor
  end

  it "detecta self.attr = param" do
    source = <<~RUBY
      class Foo
        def initialize(nome:)
          self.nome = nome
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments).to include("nome")
    expect(visitor.self_assignments["nome"][:kind]).to eq(:param)
    expect(visitor.self_assignments["nome"][:name]).to eq("nome")
  end

  it "detecta self.attr = Klass.new(...)" do
    source = <<~RUBY
      class Entity
        def initialize(email:)
          self.email = Email.new(endereco: email)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["email"][:kind]).to eq(:constant)
    expect(visitor.self_assignments["email"][:type]).to eq("Email")
  end

  it "detecta self.attr = ::Shared::Cpf.new(numero: cpf)" do
    source = <<~RUBY
      class Entity
        def initialize(cpf:)
          self.cpf = ::Shared::Cpf.new(numero: cpf)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["cpf"][:kind]).to eq(:constant)
    expect(visitor.self_assignments["cpf"][:type]).to eq("::Shared::Cpf")
  end

  it "extrai keyword defaults" do
    source = <<~RUBY
      class Foo
        def initialize(repo: MyRepo.new, name: "default", count: 42)
          self.repo = repo
          self.name = name
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.keyword_defaults["repo"]).to eq("MyRepo")
    expect(visitor.keyword_defaults["name"]).to eq("String")
    expect(visitor.keyword_defaults["count"]).to eq("Integer")
  end

  it "ignora nil como tipo de default (indica opcional, não tipo nil)" do
    source = <<~RUBY
      class Foo
        def initialize(senha: nil)
          self.senha = senha
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.keyword_defaults).not_to have_key("senha")
  end

  it "registra params com default nil em nil_default_params (pra propagar nilabilidade)" do
    # Param com default literal nil aceita nil em runtime mesmo se
    # callers só passam não-nil. O attr/ivar correspondente precisa
    # virar `T?` em vez de `T`. Trackear separadamente do
    # `keyword_defaults` (que é só pra tipo do default).
    source = <<~RUBY
      class Foo
        def initialize(nome: nil, idade: 0)
          @nome = nome
          @idade = idade
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.nil_default_params).to include("nome")
    expect(visitor.nil_default_params).not_to include("idade")  # default literal, não nil
    expect(visitor.keyword_defaults["idade"]).to eq("Integer")
    expect(visitor.keyword_defaults).not_to have_key("nome")
  end

  it "nil_default_params vazio quando initialize não tem keyword params" do
    source = <<~RUBY
      class Foo
        def initialize(nome)
          @nome = nome
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.nil_default_params).to be_empty
  end

  it "detecta self.attr = param.method como :param_method" do
    source = <<~RUBY
      class Matricular
        def initialize(aluno_dto:)
          self.errors = aluno_dto.errors
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["errors"][:kind]).to eq(:param_method)
    expect(visitor.self_assignments["errors"][:param_name]).to eq("aluno_dto")
    expect(visitor.self_assignments["errors"][:method_name]).to eq("errors")
  end

  it "detecta self.attr = [] como Array[untyped]" do
    source = <<~RUBY
      class Entity
        def initialize
          self.telefones = []
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["telefones"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["telefones"][:type]).to eq("Array[untyped]")
  end

  it "detecta self.attr = {} como Hash[untyped, untyped]" do
    source = <<~RUBY
      class Config
        def initialize
          self.options = {}
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["options"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["options"][:type]).to eq("Hash[untyped, untyped]")
  end

  it "detecta self.attr = [1, 2, 3] como Array[Integer]" do
    source = <<~RUBY
      class Entity
        def initialize
          self.items = [1, 2, 3]
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["items"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["items"][:type]).to eq("Array[Integer]")
  end

  it "detecta self.attr = { foo: 'bar', baz: 42 } como record type" do
    source = <<~RUBY
      class Config
        def initialize
          self.options = { foo: "bar", baz: 42 }
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["options"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["options"][:type]).to eq("{ foo: String, baz: Integer }")
  end

  it "detecta self.attr = ['a', 'b'] como Array[String]" do
    source = <<~RUBY
      class Entity
        def initialize
          self.tags = ["ruby", "rails"]
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["tags"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["tags"][:type]).to eq("Array[String]")
  end

  it "detecta self.attr = [1, 'a'] como Array[Integer | String]" do
    source = <<~RUBY
      class Entity
        def initialize
          self.items = [1, "a"]
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.self_assignments["items"][:kind]).to eq(:literal)
    expect(visitor.self_assignments["items"][:type]).to eq("Array[Integer | String]")
  end
end
