require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../support/temp_file_helpers"

RSpec.describe RbsInfer::NewCallCollector do
  include TempFileHelpers

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
    files = {
      "sig/record.rbs" => <<~RBS,
        class Record
          def self.find_by!: (String email) -> Record
        end
      RBS
      "caller.rb" => <<~RUBY
        def test
          record = Record.find_by!(email: "x")
          Target.new(record: record)
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      Dir.chdir(dir) do
        resolver = RbsInfer::MethodTypeResolver.new(paths)
        source = File.read(paths.last)
        result = Prism.parse(source)
        visitor = described_class.new(
          target_class: "Target",
          method_return_types: {},
          local_var_types: {},
          method_type_resolver: resolver
        )
        result.value.accept(visitor)
        expect(visitor.usages.first["record"]).to eq("Record")
      end
    end
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

  describe "self as a .new argument (regression)" do
    # `Cadastrar.new(self)` inside `Caderneta#criar_caderneta_de_vacinacao`
    # should infer the positional `initialize(caderneta)` param as
    # `Caderneta` — `self` resolves to the lexically-enclosing class.
    # Previously `self` fell through to `untyped`.
    def collect_with_self(source, target_class:, caller_class_name:, init_positional_params:)
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        caller_class_name: caller_class_name,
        init_positional_params: init_positional_params
      )
      result.value.accept(visitor)
      visitor.usages
    end

    it "infers self in an instance method as the enclosing class instance" do
      source = <<~RUBY
        class Caderneta
          def criar_caderneta_de_vacinacao
            Cadastrar.new(self).call
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"]
      )
      expect(usages.first["caderneta"]).to eq("Caderneta")
    end

    it "infers self in a singleton method as singleton(EnclosingClass)" do
      source = <<~RUBY
        class Caderneta
          def self.build
            Cadastrar.new(self)
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"]
      )
      expect(usages.first["caderneta"]).to eq("singleton(Caderneta)")
    end

    it "resolves self to the innermost lexically-enclosing class when nested" do
      source = <<~RUBY
        class Outer
          class Inner
            def make
              Target.new(self)
            end
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Outer::Inner::Target",
        caller_class_name: "Outer",
        init_positional_params: ["owner"]
      )
      expect(usages.first["owner"]).to eq("Outer::Inner")
    end

    it "falls back to untyped when self has no resolvable class context" do
      # No enclosing class node and no caller_class_name.
      source = "Target.new(self)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Target",
        method_return_types: {},
        local_var_types: {},
        init_positional_params: ["owner"]
      )
      result.value.accept(visitor)
      expect(visitor.usages.first["owner"]).to eq("untyped")
    end
  end

  describe "ivar/local name collision (regression)" do
    # The ERB caller resolver passes ivar types keyed by `@name`
    # (with prefix) and locals keyed by `name`. The collector's
    # `InstanceVariableReadNode` lookup must use the prefixed key so
    # an ivar named `@company` doesn't shadow a local named `company`
    # of unrelated type, and vice-versa.

    it "resolves @ivar via the @-prefixed key" do
      source = <<~RUBY
        Foo.new(value: @company)
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        local_var_types: { "@company" => "WideCompany", "company" => "NarrowCompany" }
      )
      expect(usages.first["value"]).to eq("WideCompany")
    end

    it "resolves local var via the unprefixed key without seeing the ivar entry" do
      source = <<~RUBY
        def test
          # `company` is a method-local, NOT the ivar @company.
          company = pick_one
          Foo.new(value: company)
        end
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        method_return_types: { "pick_one" => "NarrowCompany" },
        local_var_types: { "@company" => "WideCompany" }
      )
      expect(usages.first["value"]).to eq("NarrowCompany")
    end

    it "falls back to the unprefixed key when only that one is set (backward compat with in-class collect_class_ivar_types)" do
      # `collect_class_ivar_types` writes ivars under their bare name
      # (no `@`). The lookup should still find them.
      source = <<~RUBY
        Foo.new(value: @company)
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        local_var_types: { "company" => "LegacyCompany" }
      )
      expect(usages.first["value"]).to eq("LegacyCompany")
    end
  end
end
