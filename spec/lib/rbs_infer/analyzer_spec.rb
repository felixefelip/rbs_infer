require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../support/temp_file_helpers"

RSpec.describe RbsInfer::Analyzer do
  include TempFileHelpers

  # ─── extract_constant_path ──────────────────────────────────────

  describe ".extract_constant_path" do
    def extract(source)
      result = Prism.parse(source)
      node = result.value.statements.body.first
      RbsInfer::Analyzer.extract_constant_path(node)
    end

    it "extrai constante simples" do
      expect(extract("Foo")).to eq("Foo")
    end

    it "extrai constant path" do
      expect(extract("Foo::Bar::Baz")).to eq("Foo::Bar::Baz")
    end

    it "extrai constant path com :: prefix" do
      expect(extract("::Shared::Cpf")).to eq("::Shared::Cpf")
    end
  end

  # ─── generate_rbs (integração com arquivos temporários) ─────────

  describe "#generate_rbs" do
    it "gera RBS com attrs tipados via anotação inline" do
      files = {
        "foo.rb" => <<~RUBY
          class Foo
            attr_reader :nome #: String
            attr_reader :idade #: Integer

            def initialize(nome:, idade:)
              self.nome = nome
              self.idade = idade
            end

            private

            attr_writer :nome, :idade
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("attr_reader nome: String")
        expect(rbs).to include("attr_reader idade: Integer")
      end
    end

    it "infere tipos do initialize via call-sites" do
      entity_src = <<~RUBY
        class Entity
          attr_reader :nome

          def initialize(nome:)
            self.nome = nome
          end

          private

          attr_writer :nome
        end
      RUBY
      service_src = <<~RUBY
        class Service
          def call
            Entity.new(nome: "Felipe")
          end
        end
      RUBY

      with_temp_files("entity.rb" => entity_src, "service.rb" => service_src) do |dir, paths|
        entity = paths.find { |p| p.end_with?("entity.rb") }
        analyzer = described_class.new(target_file: entity, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("nome: String")
        expect(rbs).to include("def initialize: (nome: String) -> void")
      end
    end

    it "marca parâmetros opcionais com ? prefix" do
      entity_src = <<~RUBY
        class Entity
          attr_reader :nome, :senha

          def initialize(nome:, senha: nil)
            self.nome = nome
            self.senha = senha
          end

          private

          attr_writer :nome, :senha
        end
      RUBY
      caller_src = <<~RUBY
        class Caller
          def call
            Entity.new(nome: "Felipe", senha: "secret")
          end
        end
      RUBY

      with_temp_files("entity.rb" => entity_src, "caller.rb" => caller_src) do |dir, paths|
        entity = paths.find { |p| p.end_with?("entity.rb") }
        analyzer = described_class.new(target_file: entity, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("nome: String")
        expect(rbs).to include("?senha: String")
        expect(rbs).not_to include("?nome:")
      end
    end

    it "infere tipo de attr via self.attr = Klass.new(...)" do
      files = {
        "entity.rb" => <<~RUBY
          class Entity
            attr_reader :email

            def initialize(email_str:)
              self.email = Email.new(endereco: email_str)
            end

            private

            attr_writer :email
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("attr_reader email: Email")
      end
    end

    it "gera módulos aninhados corretamente" do
      email_src = <<~RUBY
        module Academico
          module Aluno
            class Email
              attr_accessor :endereco

              def initialize(endereco:)
                self.endereco = endereco
              end
            end
          end
        end
      RUBY
      caller_src = <<~RUBY
        class Caller
          def call
            Academico::Aluno::Email.new(endereco: "test@email.com")
          end
        end
      RUBY

      with_temp_files("foo.rb" => email_src, "caller.rb" => caller_src) do |dir, paths|
        email_file = paths.find { |p| p.end_with?("foo.rb") }
        analyzer = described_class.new(target_file: email_file, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("module Academico")
        expect(rbs).to include("  module Aluno")
        expect(rbs).to include("    class Email")
        expect(rbs).to include("      attr_accessor endereco: String")
      end
    end

    it "preserva superclass na saída" do
      files = {
        "controller.rb" => <<~RUBY
          class MyController < ApplicationController
            def index
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("class MyController < ApplicationController")
      end
    end

    it "gera void para actions de controllers" do
      files = {
        "controller.rb" => <<~RUBY
          class MyController < ApplicationController
            def create
              redirect_to root_path
            end

            def show
              render json: {}
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def create: () -> void")
        expect(rbs).to include("def show: () -> void")
      end
    end

    it "gera seção private quando há membros privados" do
      files = {
        "foo.rb" => <<~RUBY
          class Foo
            def call; end

            private

            attr_accessor :data
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("private")
        expect(rbs).to include("attr_accessor data:")
      end
    end

    it "gera def self.send_mail para mailers que herdam de ApplicationMailer" do
      files = {
        "mailer.rb" => <<~RUBY
          class MyMailer < ApplicationMailer
            #: (String nome) -> Mail::Message
            def send_mail(nome)
              mail to: "test@test.com", subject: nome
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class MyMailer < ApplicationMailer")
          expect(rbs).to include("def send_mail: (String nome) -> Mail::Message")
          expect(rbs).to include("def self.send_mail: (String nome) -> Mail::Message")
        end
      end
    end

    it "não gera def self.send_mail para classes que não são mailers" do
      files = {
        "service.rb" => <<~RUBY
          class MyService
            def send_mail(nome)
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).not_to include("def self.send_mail")
      end
    end

    # Regression: ReturnTypeResolver used to filter members with
    # `m.kind == :method`, dropping the `:class_method` tag that
    # ClassMemberCollector assigns to `def self.X`. As a result Steep's
    # inferred return type for singleton methods was discarded and the
    # final RBS dropped to `untyped`. The basic node_type inferrer can't
    # type `"hello".upcase` (chain call), so this body specifically
    # exercises the Steep bridge → resolver path.
    it "resolve o tipo de retorno de def self.X quando depende de inferência via Steep" do
      files = {
        "factory.rb" => <<~RUBY
          class GreetFactory
            def self.greet
              "hello".upcase
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def self.greet: () -> String")
        expect(rbs).not_to include("def self.greet: () -> untyped")
      end
    end

    it "atualiza def self.X mesmo quando há um def X (instance) homônimo no mesmo lugar" do
      files = {
        "factory.rb" => <<~RUBY
          class TwinNames
            def self.run
              new.run.upcase
            end

            def run
              "abc"
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        # Both surfaces should resolve away from untyped.
        expect(rbs).to include("def self.run: () -> String")
        expect(rbs).to include("def run: () -> String")
      end
    end

    # Regression: methods inside `class << self` are singleton (class)
    # methods, but the `self.` receiver is absent on the node, so they were
    # collected as instance methods. A `consume` defined both as a class
    # method (in `class << self`) and an instance method then collapsed into
    # two `def consume:` lines in the same (instance) scope. They must split
    # into `def self.consume` and `def consume`, each resolving on its own.
    it "separa class << self e instância homônimos em def self.X e def X" do
      files = {
        "magic_link.rb" => <<~RUBY
          class MagicLink
            class << self
              def consume(code)
                42
              end
            end

            def consume
              "done"
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        # Exactly one of each surface — no duplicated `def consume:`.
        expect(rbs.scan(/^\s*def self\.consume:/).size).to eq(1)
        expect(rbs.scan(/^\s*def consume:/).size).to eq(1)
        # Distinct scopes keep distinct signatures — the return types do not
        # bleed between the singleton and the instance method.
        expect(rbs).to include("def self.consume: (untyped code) -> Integer")
        expect(rbs).to include("def consume: () -> String")
      end
    end

    # Regression: `has_nil_return?` annotates a method whose body has an
    # early `return` (implicit nil) with `?`. The selectors that invoke it
    # were `m.kind == :method`, so singleton methods missed the wrap.
    it "anota def self.X com ? quando o body tem return implícito nil" do
      files = {
        "factory.rb" => <<~RUBY
          class EarlyReturn
            def self.maybe_greet(empty)
              return if empty
              "hi".upcase
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def self.maybe_greet: (untyped empty) -> String?")
      end
    end

    # Regression: block generic resolution (`.map { ... }`) lives in the
    # same loop that updates already-typed methods. Singleton methods
    # need that loop to fire on them too — otherwise `.map`'s
    # `Array[untyped]` declaration sticks.
    it "resolve generic de bloco (.map) dentro de def self.X" do
      files = {
        "factory.rb" => <<~RUBY
          class MapFactory
            def self.names
              [1, 2, 3].map { |n| n.to_s }
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def self.names: () -> Array[String]")
      end
    end

    it "resolve tipos inter-procedurais via method chain (receiver.method)" do
      dto_src = <<~RUBY
        class Dto
          #: -> String
          def cpf!
            cpf || raise
          end

          #: -> String
          def nome!
            nome || raise
          end
        end
      RUBY
      entity_src = <<~RUBY
        class Entity
          attr_reader :nome, :cpf

          def initialize(nome:, cpf:)
            self.nome = nome
            self.cpf = cpf
          end

          private

          attr_writer :nome, :cpf
        end
      RUBY
      service_src = <<~RUBY
        class Service
          attr_accessor :aluno_dto #: Dto

          def call
            dto = aluno_dto
            Entity.new(nome: dto.nome!, cpf: dto.cpf!)
          end
        end
      RUBY

      with_temp_files("dto.rb" => dto_src, "entity.rb" => entity_src, "service.rb" => service_src) do |dir, paths|
        entity = paths.find { |p| p.end_with?("entity.rb") }
        analyzer = described_class.new(target_file: entity, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("nome: String")
        expect(rbs).to include("cpf: String")
      end
    end

    it "resolve tipo de param cross-class via call-site (Email.endereco = String)" do
      entity_src = <<~RUBY
        module MyApp
          class Entity
            attr_reader :email

            def initialize(email:)
              self.email = Email.new(endereco: email)
            end

            private

            attr_writer :email
          end
        end
      RUBY
      email_src = <<~RUBY
        module MyApp
          class Email
            attr_accessor :endereco

            def initialize(endereco:)
              self.endereco = endereco
            end
          end
        end
      RUBY
      caller_src = <<~RUBY
        class Caller
          def call
            MyApp::Entity.new(email: "test@email.com")
          end
        end
      RUBY

      with_temp_files("entity.rb" => entity_src, "email.rb" => email_src, "caller.rb" => caller_src) do |dir, paths|
        email = paths.find { |p| p.end_with?("email.rb") }
        analyzer = described_class.new(target_file: email, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("endereco: String")
      end
    end

    it "resolve return type de método que retorna attr conhecido (to_s -> endereco)" do
      email_src = <<~RUBY
        module MyApp
          class Email
            attr_accessor :endereco

            def initialize(endereco:)
              self.endereco = endereco
            end

            def to_s
              endereco
            end
          end
        end
      RUBY
      caller_src = <<~RUBY
        class Caller
          def call
            MyApp::Email.new(endereco: "test@email.com")
          end
        end
      RUBY

      with_temp_files("email.rb" => email_src, "caller.rb" => caller_src) do |dir, paths|
        email = paths.find { |p| p.end_with?("email.rb") }
        analyzer = described_class.new(target_file: email, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def to_s: () -> String")
        expect(rbs).not_to include("def to_s: () -> untyped")
      end
    end

    it "infere return type de método via literal na última expressão (string interpolation, integer, etc.)" do
      src = <<~RUBY
        class Foo
          attr_reader :nome #: String

          def to_s
            "(\#{nome})"
          end

          def count
            42
          end

          def ratio
            3.14
          end

          def label
            :foo
          end

          def active?
            true
          end
        end
      RUBY

      with_temp_files("foo.rb" => src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("def to_s: () -> String")
          expect(rbs).to include("def count: () -> Integer")
          expect(rbs).to include("def ratio: () -> Float")
          expect(rbs).to include("def label: () -> Symbol")
          expect(rbs).to include("def active?: () -> bool")
        end
      end
    end

    it "infere return type via Klass.new(...) na última expressão" do
      src = <<~RUBY
        module MyApp
          class Factory
            def build
              MyApp::Entity.new(nome: "x")
            end
          end
        end
      RUBY

      with_temp_files("my_app/factory.rb" => src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def build: () -> MyApp::Entity")
      end
    end

    it "infere return type via chamada de método com tipo conhecido (self.metodo)" do
      src = <<~RUBY
        module MyApp
          class Service
            attr_reader :entity #: MyApp::Entity

            def build_entity
              MyApp::Entity.new(nome: "x")
            end

            def resultado
              build_entity
            end
          end
        end
      RUBY

      with_temp_files("my_app/service.rb" => src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("def build_entity: () -> MyApp::Entity")
          expect(rbs).to include("def resultado: () -> MyApp::Entity")
        end
      end
    end

    it "infere return type via receiver.method (method chain)" do
      entity_src = <<~RUBY
        module MyApp
          class Entity
            attr_reader :nome #: String

            def initialize(nome:)
              self.nome = nome
            end
          end
        end
      RUBY
      service_src = <<~RUBY
        module MyApp
          class Service
            attr_reader :entity #: MyApp::Entity

            def nome_do_entity
              entity.nome
            end
          end
        end
      RUBY

      with_temp_files("my_app/entity.rb" => entity_src, "my_app/service.rb" => service_src) do |dir, paths|
        service = paths.find { |p| p.end_with?("service.rb") }
        analyzer = described_class.new(target_file: service, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def nome_do_entity: () -> String")
      end
    end

    it "infere return type de attr << Klass.new como Array[Klass]" do
      entity_src = <<~RUBY
        module MyApp
          class Entity
            attr_reader :items

            def initialize
              self.items = []
            end

            def add_item(name:)
              items << Item.new(name:)
            end

            private

            attr_writer :items
          end
        end
      RUBY

      with_temp_files("my_app/entity.rb" => entity_src) do |dir, paths|
        entity = paths.find { |p| p.end_with?("entity.rb") }
        analyzer = described_class.new(target_file: entity, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("attr_reader items: Array[Item]")
        expect(rbs).to include("def add_item: (name: untyped) -> Array[Item]")
      end
    end

    %i[push append unshift prepend].each do |method_name|
      it "infere return type de attr.#{method_name}(Klass.new) como Array[Klass]" do
        entity_src = <<~RUBY
          module MyApp
            class Entity
              attr_reader :items

              def initialize
                self.items = []
              end

              def add_item(name:)
                items.#{method_name}(Item.new(name:))
              end

              private

              attr_writer :items
            end
          end
        RUBY

        with_temp_files("my_app/entity.rb" => entity_src) do |dir, paths|
          entity = paths.find { |p| p.end_with?("entity.rb") }
          analyzer = described_class.new(target_file: entity, source_files: paths)
          rbs = analyzer.generate_rbs

          expect(rbs).to include("attr_reader items: Array[Item]")
          expect(rbs).to include("def add_item: (name: untyped) -> Array[Item]")
        end
      end
    end

    it "infere tipo de attr via param.method quando tipo do param é conhecido" do
      dto_src = <<~RUBY
        module MyApp
          class Dto
            attr_reader :nome #: String

            def initialize(nome:)
              self.nome = nome
            end

            #: -> String
            def resultado
              nome
            end

            private

            attr_writer :nome
          end
        end
      RUBY
      usecase_src = <<~RUBY
        module MyApp
          class Usecase
            attr_accessor :resultado

            def initialize(dto:)
              self.resultado = dto.resultado
            end
          end
        end
      RUBY
      caller_src = <<~RUBY
        class Caller
          def call
            dto = MyApp::Dto.new(nome: "test")
            MyApp::Usecase.new(dto: dto)
          end
        end
      RUBY

      with_temp_files("my_app/dto.rb" => dto_src, "my_app/usecase.rb" => usecase_src, "caller.rb" => caller_src) do |dir, paths|
        usecase = paths.find { |p| p.end_with?("usecase.rb") }
        analyzer = described_class.new(target_file: usecase, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("attr_accessor resultado: String")
      end
    end

    it "infere tipos de parâmetros de métodos via chamadas intra-classe" do
      usecase_src = <<~RUBY
        module MyApp
          class Usecase
            def call
              entity = ::MyApp::Entity.new(nome: "test")
              processar(entity:)
            end

            private

            def processar(entity:)
              entity.nome
            end
          end
        end
      RUBY

      with_temp_files("my_app/usecase.rb" => usecase_src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("def processar: (entity: ::MyApp::Entity)")
      end
    end

    it "gera RBS válido para módulo com métodos que recebem blocos" do
      helper_src = <<~RUBY
        module MyHelper
          def wrapper(id:, name:, data: {}, **options, &block)
            tag.section(id: id, &block)
          end

          def simple_yield(&block)
            yield if block_given?
          end

          def mixed(items, label:, &block)
            items.each(&block)
          end
        end
      RUBY

      with_temp_files("my_helper.rb" => helper_src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          # Block should be outside parentheses
          expect(rbs).to include("def wrapper: (id: untyped, name: untyped, ?data: untyped, **untyped) ?{ (untyped) -> untyped } -> untyped")
          expect(rbs).to include("def simple_yield: () ?{ (untyped) -> untyped } -> untyped")
          expect(rbs).to include("def mixed: (untyped items, label: untyped) ?{ (untyped) -> untyped } -> untyped")

          # Block must NEVER be inside parentheses
          expect(rbs).not_to include(", ?{")

          # Output must be valid RBS
          expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
        end
      end
    end

    it "não corrompe return type de método com bloco ao resolver tipos" do
      helper_src = <<~RUBY
        module MyHelper
          def wrapper(&block)
            "hello"
          end

          def count_items(items, &block)
            42
          end
        end
      RUBY

      with_temp_files("my_helper.rb" => helper_src) do |dir, paths|
        analyzer = described_class.new(target_file: paths.first, source_files: paths)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          # Return types should be resolved correctly
          expect(rbs).to include("def wrapper: () ?{ (untyped) -> untyped } -> String")
          expect(rbs).to include("def count_items: (untyped items) ?{ (untyped) -> untyped } -> Integer")

          # The -> untyped inside the block must not be replaced
          expect(rbs).not_to include("-> String }")
          expect(rbs).not_to include("-> Integer }")

          # Output must be valid RBS
          expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
        end
      end
    end
  end

  # ─── módulos aninhados (felixefelip/rbs_infer#22) ───────────────

  describe "#generate_rbs com módulo aninhado incluído" do
    # Carrega o RBS gerado num ambiente RBS real (com core) e resolve a
    # classe — falha com NoMixinFoundError se houver `include` pendurado.
    def assert_valid_rbs(rbs, class_name)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "generated.rbs")
        File.write(path, rbs)
        loader = RBS::EnvironmentLoader.new
        loader.add(path: Pathname(path))
        env = RBS::Environment.from_loader(loader).resolve_type_names
        expect { RBS::DefinitionBuilder.new(env: env).build_instance(RBS::TypeName.parse(class_name)) }
          .not_to raise_error
      end
    end

    let(:report_source) do
      <<~RUBY
        class Report
          module Formatting
            def title
              @title
            end

            def title=(value)
              @title = value
            end
          end
          include Formatting

          def header
            title
          end
        end
      RUBY
    end

    it "preserva o módulo aninhado em vez de achatar os métodos" do
      with_temp_files("report.rb" => report_source) do |_dir, paths|
        rbs = described_class.new(target_file: paths.first, source_files: paths).generate_rbs

        expect(rbs).to include("module Formatting")
        # métodos do módulo ficam DENTRO dele, não no corpo da classe
        expect(rbs).to match(/module Formatting.*def title.*def title=.*end/m)
        expect(rbs).to include("include Formatting")
      end
    end

    it "gera RBS válido (sem include pendurado)" do
      with_temp_files("report.rb" => report_source) do |_dir, paths|
        rbs = described_class.new(target_file: paths.first, source_files: paths).generate_rbs

        assert_valid_rbs(rbs, "::Report")
      end
    end

    it "mantém métodos diretos da classe fora do módulo" do
      with_temp_files("report.rb" => report_source) do |_dir, paths|
        rbs = described_class.new(target_file: paths.first, source_files: paths).generate_rbs

        # `header` é método direto de Report, não do módulo Formatting
        expect(rbs).to match(/^  def header:/)
      end
    end
  end

  # ─── resolve_namespace_classes ─────────────────────────────────

  describe "#resolve_namespace_classes (via generate_rbs)" do
    it "usa 'module' para namespace definido com sintaxe compacta (module Foo::Bar)" do
      files = {
        "foo/bar.rb" => "module Foo::Bar\nend\n",
        "foo/bar/baz.rb" => "module Foo\n  module Bar\n    class Baz\n    end\n  end\nend\n"
      }

      with_temp_files(files) do |dir, paths|
        target = paths.find { |p| p.end_with?("foo/bar/baz.rb") }
        analyzer = described_class.new(target_file: target, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("module Foo")
        expect(rbs).to include("module Bar")
        expect(rbs).not_to include("class Bar")
        expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
      end
    end

    it "usa 'class' para namespace quando outro arquivo tem sufixo igual mas caminho diferente" do
      # Reproduz o caso MagicLink: "via_magic_link.rb" não deve ser confundido com "magic_link.rb"
      files = {
        "models/magic_link.rb"                              => "class MagicLink\nend\n",
        "controllers/via_magic_link.rb"                     => "module ViaMagicLink\nend\n",
        "models/magic_link/code.rb"                         => "module MagicLink::Code\nend\n"
      }

      with_temp_files(files) do |dir, paths|
        target = paths.find { |p| p.end_with?("magic_link/code.rb") }
        analyzer = described_class.new(target_file: target, source_files: paths)
        rbs = analyzer.generate_rbs

        expect(rbs).to include("class MagicLink")
        expect(rbs).not_to include("module MagicLink")
        expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
      end
    end

    # ─── Setter marker classes (felixefelip/rbs_infer#11) ──────────

    context "setter marker classes" do
      it "gera marker nested class para setter que narrow attr_accessor" do
        # `attr_accessor :name #: String?` declara explicitamente o
        # tipo wide do ivar. set_default_name escreve "TBA Venue"
        # (String, strict subtype de String?) → marker
        # AfterSetDefaultName. clear_name escreve nil (também strict
        # subtype) → marker AfterClearName com override pra nil.
        files = {
          "venue.rb" => <<~RUBY
            class Venue
              attr_accessor :name #: String?

              def initialize(name: nil)
                @name = name
              end

              def set_default_name
                @name = "TBA Venue"
              end

              def clear_name
                @name = nil
              end
            end
          RUBY
        }

        with_temp_files(files) do |_dir, paths|
          analyzer = described_class.new(target_file: paths.first, source_files: paths)
          rbs = analyzer.generate_rbs

          aggregate_failures do
            expect(rbs).to include("class AfterSetDefaultName")
            expect(rbs).to include("attr_reader name: String")
            expect(rbs).to include("class AfterClearName")
            expect(rbs).to include("attr_reader name: nil")
            expect { RBS::Parser.parse_signature(rbs) }.not_to raise_error
          end
        end
      end

      it "não gera marker para classe sem attr_reader observável" do
        files = {
          "isolated.rb" => <<~RUBY
            class Isolated
              def initialize(name: nil)
                @name = name
              end

              def set_default_name
                @name = "TBA"
              end
            end
          RUBY
        }

        with_temp_files(files) do |_dir, paths|
          analyzer = described_class.new(target_file: paths.first, source_files: paths)
          rbs = analyzer.generate_rbs

          expect(rbs).not_to include("class After")
        end
      end
    end
  end

  # ─── Integração com arquivos reais do projeto ───────────────────

  describe "#generate_rbs (integração com arquivos reais)", :integration do
    let(:source_files) { Dir["engines/**/*.rb", "app/**/*.rb"] }

    context "Academico::Aluno::Entity" do
      let(:target_file) { "engines/academico/app/domains/academico/aluno/entity.rb" }

      it "gera RBS correto" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("module Academico")
          expect(rbs).to include("class Entity")
          expect(rbs).to include("nome: String")
          expect(rbs).to include("email: Email")
          expect(rbs).to include("cpf: ::Shared::Cpf")
          expect(rbs).to match(/\?senha: String\?/)
          expect(rbs).to include("private")
        end
      end
    end

    context "Academico::Aluno::Email" do
      let(:target_file) { "engines/academico/app/domains/academico/aluno/email.rb" }

      it "infere endereco como String via cross-class analysis" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("module Academico")
          expect(rbs).to include("module Aluno")
          expect(rbs).to include("class Email")
          expect(rbs).to include("endereco: String")
          expect(rbs).to include("def to_s: () -> String")
        end
      end
    end

    context "Academico::Aluno::Matricular" do
      let(:target_file) { "engines/academico/app/usecases/academico/aluno/matricular.rb" }

      it "infere tipos de attrs sem anotação via call-sites" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class Matricular")
          expect(rbs).to include("errors: ActiveModel::Errors")
          expect(rbs).to include("def call:")
          expect(rbs).to include("aluno_dto: Academico::Aluno::Matricular::Dto")
          expect(rbs).to match(/aluno_repository:.*Impl/)
          expect(rbs).to include("def publicar_evento: (aluno: ::Academico::Aluno::Entity)")
        end
      end
    end

    context "Academico::Aluno::Matricular::SuccessMailer" do
      let(:target_file) { "engines/academico/app/usecases/academico/aluno/matricular/success_mailer.rb" }

      it "gera def self.send_mail automaticamente" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class SuccessMailer < ApplicationMailer")
          expect(rbs).to include("def send_mail: (Academico::Aluno::Entity aluno) -> Mail::Message")
          expect(rbs).to include("def self.send_mail: (Academico::Aluno::Entity aluno) -> Mail::Message")
        end
      end
    end

    context "Finance::Client::Enroll" do
      let(:target_file) { "engines/finance/app/models/finance/client/enroll.rb" }

      it "infere attrs client e card via call-sites" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class Enroll")
          expect(rbs).to include("client: Finance::Client::Entity")
          expect(rbs).to include("card: Finance::Card::Entity")
        end
      end
    end

    context "Finance::ClientsController" do
      let(:target_file) { "engines/finance/app/controllers/finance/clients_controller.rb" }

      it "gera void para actions e infere return types de helpers" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class ClientsController < ApplicationController")
          expect(rbs).to include("def create: () -> void")
          expect(rbs).to include("build_client: () -> Finance::Client::Entity")
          expect(rbs).to include("build_card: () -> Finance::Card::Entity")
        end
      end
    end

    context "Marketing::LeadsController" do
      let(:target_file) { "engines/marketing/app/controllers/marketing/leads_controller.rb" }

      it "infere tipo de attr lead" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class LeadsController < ApplicationController")
          expect(rbs).to include("lead: Marketing::Lead::Entity")
        end
      end
    end

    context "Academico::Aluno::Telefone" do
      let(:target_file) { "engines/academico/app/domains/academico/aluno/telefone.rb" }

      it "infere tipos de attrs via forwarding wrapper (Entity#adicionar_telefone → Telefone.new)" do
        analyzer = described_class.new(target_file: target_file, source_files: source_files)
        rbs = analyzer.generate_rbs

        aggregate_failures do
          expect(rbs).to include("class Telefone")
          expect(rbs).to include("ddd: String?")
          expect(rbs).to include("numero: String?")
          expect(rbs).to include("def initialize: (ddd: String?, numero: String?) -> void")
          expect(rbs).to include("def to_s: () -> String")
        end
      end
    end
  end
end
