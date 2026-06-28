require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

RSpec.describe RbsInfer::Inference::NewCallCollector do
  include TempFileHelpers

  # Test-only default for the required `constant_arg_resolver` (#46); these
  # specs don't exercise constant args, so a null-tier resolver suffices.
  def null_constant_resolver
    RbsInfer::Inference::ConstantArgTypeResolver.new(steep_bridge: nil, caller_constant_types: {})
  end

  def collect_usages(source, target_class:, method_return_types: {}, local_var_types: {})
    result = Prism.parse(source)
    visitor = described_class.new(
      target_class: target_class,
      method_return_types: method_return_types,
      local_var_types: local_var_types,
      constant_arg_resolver: null_constant_resolver
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
        resolver = RbsInfer::Signatures::MethodTypeResolver.new(paths, constant_resolver: fake_constant_resolver)
        source = File.read(paths.last)
        result = Prism.parse(source)
        visitor = described_class.new(
          target_class: "Target",
          method_return_types: {},
          local_var_types: {},
          method_type_resolver: resolver,
          constant_arg_resolver: null_constant_resolver
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
    def collect_with_self(source, target_class:, caller_class_name:, init_positional_params:, self_types_by_method: {})
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        caller_class_name: caller_class_name,
        init_positional_params: init_positional_params,
        self_types_by_method: self_types_by_method,
        constant_arg_resolver: null_constant_resolver
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

    # After-validation callback narrowing: inside an `after_create` handler
    # the record is validated, so `self` (and thus `Cadastrar.new(self)`)
    # should be `Caderneta & Caderneta::Validated`. The refined self type
    # comes from the callback sidecar (SteepBridge#callback_self_types) since
    # Steep keeps `self` abstract in its typing output.
    it "prefers the callback-refined self type over the lexical class" do
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
        init_positional_params: ["caderneta"],
        self_types_by_method: { "criar_caderneta_de_vacinacao" => "Caderneta & Caderneta::Validated" }
      )
      expect(usages.first["caderneta"]).to eq("Caderneta & Caderneta::Validated")
    end

    it "uses the lexical class for methods not covered by a callback entry" do
      source = <<~RUBY
        class Caderneta
          def some_other_method
            Cadastrar.new(self)
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"],
        self_types_by_method: { "criar_caderneta_de_vacinacao" => "Caderneta & Caderneta::Validated" }
      )
      expect(usages.first["caderneta"]).to eq("Caderneta")
    end

    it "falls back to untyped when self has no resolvable class context" do
      # No enclosing class node and no caller_class_name.
      source = "Target.new(self)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Target",
        method_return_types: {},
        local_var_types: {},
        init_positional_params: ["owner"],
        constant_arg_resolver: null_constant_resolver
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

  describe "target-method calls through marker-decorated / self-refined receivers" do
    # Peça B: the receiver type carries markers, i.e. it's an intersection
    # like `Caderneta & Caderneta::Validated`. `match_class?` must recognize
    # the target class as one of the intersection's components, otherwise the
    # call is silently dropped and the argument types are never collected.
    it "matches a target call whose receiver resolves to an intersection type" do
      source = "caderneta.qtde_por_vacina(v)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Caderneta",
        method_return_types: { "caderneta" => "Caderneta & Caderneta::Validated", "v" => "Vacina" },
        local_var_types: {},
        target_methods: { "qtde_por_vacina" => ["vacina"] },
        constant_arg_resolver: null_constant_resolver
      )
      result.value.accept(visitor)

      expect(visitor.method_call_usages["qtde_por_vacina"]).to eq([{ "vacina" => "Vacina" }])
    end

    # Peça A: inside a method whose `self` is callback-refined, a
    # `self.<association>` used as the receiver OR as an argument resolves
    # against that refined self (the marker-decorated reader), not the base
    # nilable reader — so both the receiver match and the argument type pick
    # up the validated type.
    it "resolves self.<association> receiver and argument against the refined self" do
      files = {
        "sig/holder.rbs" => <<~RBS,
          class Holder
            def thing: () -> Thing?
            def other: () -> Other?
          end

          class Holder::Validated
            def thing: () -> (Thing & Thing::Validated)
            def other: () -> (Other & Other::Validated)
          end

          class Thing
          end
          class Thing::Validated
          end
          class Other
          end
          class Other::Validated
          end
        RBS
        "caller.rb" => <<~RUBY
          class Holder
            def m
              thing.target_method(other)
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        Dir.chdir(dir) do
          resolver = RbsInfer::Signatures::MethodTypeResolver.new(paths, constant_resolver: fake_constant_resolver)
          source = File.read(File.join(dir, "caller.rb"))
          result = Prism.parse(source)
          visitor = described_class.new(
            target_class: "Thing",
            method_return_types: {},
            local_var_types: {},
            method_type_resolver: resolver,
            caller_class_name: "Holder",
            target_methods: { "target_method" => ["arg"] },
            self_types_by_method: { "m" => "Holder & Holder::Validated" },
            constant_arg_resolver: null_constant_resolver
          )
          result.value.accept(visitor)

          expect(visitor.method_call_usages["target_method"]).to eq(
            [{ "arg" => "Other & Other::Validated" }]
          )
        end
      end
    end
  end
end
