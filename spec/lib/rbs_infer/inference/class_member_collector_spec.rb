require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::ClassMemberCollector do
  def collect(source)
    result = Prism.parse(source)
    comments = result.comments
    lines = source.lines
    visitor = described_class.new(comments: comments, lines: lines)
    result.value.accept(visitor)
    visitor
  end

  it "coleta attr_reader com tipo inline" do
    source = <<~RUBY
      class Foo
        attr_reader :nome #: String
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "nome" }
    expect(member).not_to be_nil
    expect(member.kind).to eq(:attr_reader)
    expect(member.signature).to eq("nome: String")
  end

  it "coleta attr_accessor sem tipo como untyped" do
    source = <<~RUBY
      class Foo
        attr_accessor :idade
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "idade" }
    expect(member.kind).to eq(:attr_accessor)
    expect(member.signature).to eq("idade: untyped")
  end

  it "coleta método com assinatura rbs-inline (#:)" do
    source = <<~RUBY
      class Foo
        #: -> void
        def call
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "call" }
    expect(member.kind).to eq(:method)
    expect(member.signature).to eq("call: -> void")
  end

  it "coleta método com assinatura @rbs" do
    source = <<~RUBY
      class Foo
        # @rbs (nome: String) -> void
        def initialize(nome:)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "initialize" }
    expect(member.signature).to eq("initialize: (nome: String) -> void")
  end

  it "rastreia visibilidade private" do
    source = <<~RUBY
      class Foo
        def call; end

        private

        attr_accessor :nome
        def helper; end
      end
    RUBY

    collector = collect(source)
    expect(collector.members.find { |m| m.name == "call" }.visibility).to eq(:public)
    expect(collector.members.find { |m| m.name == "nome" }.visibility).to eq(:private)
    expect(collector.members.find { |m| m.name == "helper" }.visibility).to eq(:private)
  end

  it "detecta superclass" do
    source = <<~RUBY
      class MyController < ApplicationController
        def index; end
      end
    RUBY

    collector = collect(source)
    expect(collector.superclass_name).to eq("ApplicationController")
  end

  it "usa void como return type para actions de controllers" do
    source = <<~RUBY
      class MyController < ApplicationController
        def create; end
        def index; end
      end
    RUBY

    collector = collect(source)
    create_member = collector.members.find { |m| m.name == "create" }
    expect(create_member.signature).to include("-> void")
  end

  it "infere return type de métodos simples" do
    source = <<~RUBY
      class Foo
        def build_name
          "hello"
        end

        def build_count
          42
        end
      end
    RUBY

    collector = collect(source)
    expect(collector.members.find { |m| m.name == "build_name" }.signature).to include("-> String")
    expect(collector.members.find { |m| m.name == "build_count" }.signature).to include("-> Integer")
  end

  it "defere o return type quando a última expressão é uma constante (felixefelip/rbs_infer#46)" do
    source = <<~RUBY
      class Foo
        def status
          ACTIVE
        end

        def continue
          Loofah::Scrubber::CONTINUE
        end
      end
    RUBY

    collector = collect(source)
    # O nome cru não é tipo RBS válido para uma constante-valor (nem o tipo
    # certo para classe/módulo: seria singleton). Fica untyped; o Analyzer
    # resolve via Steep.
    expect(collector.members.find { |m| m.name == "status" }.signature).to eq("status: () -> untyped")
    expect(collector.members.find { |m| m.name == "continue" }.signature).to eq("continue: () -> untyped")
  end

  describe "class << self (métodos singleton)" do
    it "classifica métodos definidos em `class << self` como class_method" do
      source = <<~RUBY
        class Foo
          class << self
            def build(name)
            end

            def reset
            end
          end
        end
      RUBY

      collector = collect(source)
      build = collector.members.find { |m| m.name == "build" }
      reset = collector.members.find { |m| m.name == "reset" }
      expect(build.kind).to eq(:class_method)
      expect(reset.kind).to eq(:class_method)
    end

    it "mantém método de classe e de instância de mesmo nome como membros distintos" do
      source = <<~RUBY
        class MagicLink
          class << self
            def consume(code)
            end
          end

          def consume
          end
        end
      RUBY

      consumes = collect(source).members.select { |m| m.name == "consume" }
      expect(consumes.map(&:kind)).to contain_exactly(:class_method, :method)
      # o método de classe carrega o parâmetro; o de instância não
      class_consume = consumes.find { |m| m.kind == :class_method }
      inst_consume = consumes.find { |m| m.kind == :method }
      expect(class_consume.signature).to include("code")
      expect(inst_consume.signature).not_to include("code")
    end

    it "não vaza visibilidade de dentro de `class << self` para os métodos seguintes" do
      source = <<~RUBY
        class Foo
          class << self
            private

            def secret_builder
            end
          end

          def public_api
          end
        end
      RUBY

      collector = collect(source)
      expect(collector.members.find { |m| m.name == "public_api" }.visibility).to eq(:public)
    end

    it "não classifica métodos de `class << outro_objeto` como class_method" do
      source = <<~RUBY
        class Foo
          OBJ = Object.new
          class << OBJ
            def bar
            end
          end
        end
      RUBY

      bar = collect(source).members.find { |m| m.name == "bar" }
      expect(bar.kind).not_to eq(:class_method)
    end

    # A singleton attr (`class << self; attr_accessor :x`) backs the
    # class-instance variable `@x`, a slot distinct from an instance attr of
    # the same name; the `singleton` flag lets consumers tell them apart
    # (felixefelip/rbs_infer#86).
    it "marca attr de `class << self` com singleton: true" do
      source = <<~RUBY
        class Foo
          attr_accessor :instance_one

          class << self
            attr_reader :singleton_one
          end
        end
      RUBY

      collector = collect(source)
      instance_one = collector.members.find { |m| m.name == "instance_one" }
      singleton_one = collector.members.find { |m| m.name == "singleton_one" }
      expect(instance_one.singleton).to be_falsey
      expect(singleton_one.singleton).to be(true)
    end
  end

  describe "delegate parsing" do
    it "collects a basic delegate call" do
      source = <<~RUBY
        class Post
          delegate :email, to: :user
        end
      RUBY

      collector = collect(source)
      expect(collector.delegates.size).to eq(1)
      info = collector.delegates.first
      expect(info.methods).to eq(["email"])
      expect(info.target).to eq("user")
      expect(info.prefix).to be_nil
      expect(info.allow_nil).to eq(false)
    end

    it "collects delegate with prefix: true" do
      source = <<~RUBY
        class Post
          delegate :email, to: :user, prefix: true
        end
      RUBY

      info = collect(source).delegates.first
      expect(info.prefix).to eq(true)
    end

    it "collects delegate with custom symbol prefix" do
      source = <<~RUBY
        class Post
          delegate :email, to: :user, prefix: :author
        end
      RUBY

      info = collect(source).delegates.first
      expect(info.prefix).to eq("author")
    end

    it "collects delegate with allow_nil: true" do
      source = <<~RUBY
        class Post
          delegate :email, to: :user, allow_nil: true
        end
      RUBY

      info = collect(source).delegates.first
      expect(info.allow_nil).to eq(true)
    end

    it "collects multiple delegated methods in one call" do
      source = <<~RUBY
        class Post
          delegate :name, :email, :phone, to: :user
        end
      RUBY

      info = collect(source).delegates.first
      expect(info.methods).to eq(["name", "email", "phone"])
    end

    it "ignores delegate without to: keyword" do
      source = <<~RUBY
        class Post
          delegate :email
        end
      RUBY

      expect(collect(source).delegates).to be_empty
    end
  end

  it "gera assinatura com keyword params" do
    source = <<~RUBY
      class Foo
        def initialize(nome:, email:, senha: nil)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "initialize" }
    expect(member.signature).to include("nome: untyped")
    expect(member.signature).to include("email: untyped")
    expect(member.signature).to include("?senha: untyped")
  end

  describe "default de param opcional que é constante (felixefelip/rbs_infer#46)" do
    it "defere a resolução: emite ?untyped e registra o nó da constante" do
      source = <<~RUBY
        class Foo
          def bar(actions = Webhook::PERMITTED_ACTIONS)
          end
        end
      RUBY

      collector = collect(source)
      member = collector.members.find { |m| m.name == "bar" }
      # O nome cru da constante não é um tipo RBS válido para uma
      # constante-valor; o tipo é resolvido depois no Analyzer.
      expect(member.signature).to eq("bar: (?untyped actions) -> untyped")
      expect(member.param_constant_defaults.keys).to eq(["actions"])
      expect(member.param_constant_defaults["actions"]).to be_a(Prism::ConstantPathNode)
    end

    it "mantém a inferência inline para defaults literais" do
      source = <<~RUBY
        class Foo
          def bar(length = 150, name = "x")
          end
        end
      RUBY

      collector = collect(source)
      member = collector.members.find { |m| m.name == "bar" }
      expect(member.signature).to eq("bar: (?Integer length, ?String name) -> untyped")
      expect(member.param_constant_defaults).to be_empty
    end
  end

  it "coloca bloco após parênteses na assinatura RBS" do
    source = <<~RUBY
      class Foo
        def tag(id:, name:, **options, &block)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "tag" }
    expect(member.signature).to eq("tag: (id: untyped, name: untyped, **untyped) ?{ (untyped) -> untyped } -> untyped")
    expect(member.signature).not_to include(", ?{")
  end

  it "gera assinatura com bloco sem outros params" do
    source = <<~RUBY
      class Foo
        def each(&block)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "each" }
    expect(member.signature).to eq("each: () ?{ (untyped) -> untyped } -> untyped")
  end

  it "gera assinatura com params posicionais e bloco" do
    source = <<~RUBY
      class Foo
        def map(items, &block)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "map" }
    expect(member.signature).to eq("map: (untyped items) ?{ (untyped) -> untyped } -> untyped")
  end

  it "não sobrescreve superclass com a de uma classe aninhada" do
    source = <<~RUBY
      class Webhook::Delivery < ApplicationRecord
        class ResponseTooLarge < StandardError; end

        def deliver; end
      end
    RUBY

    collector = collect(source)
    expect(collector.superclass_name).to eq("ApplicationRecord")
  end

  describe "classes aninhadas" do
    def collect_for(source, target_class:)
      result = Prism.parse(source)
      visitor = described_class.new(comments: result.comments, lines: source.lines, target_class: target_class)
      result.value.accept(visitor)
      visitor
    end

    let(:nested_source) do
      <<~RUBY
        class Example2
          class User
            attr_reader :name

            def initialize(name:)
              @name = name
            end
          end

          def self.run; end
        end
      RUBY
    end

    # A nested class is its own target (TargetDiscovery promotes it), so its
    # members belong to that target's pass. Attributing them to the enclosing
    # class flattened them into it — Example2 would claim an `initialize(name:)`
    # it does not have.
    it "não atribui membros de uma classe aninhada à classe externa" do
      collector = collect_for(nested_source, target_class: "Example2")

      expect(collector.members.map(&:name)).to eq(["run"])
    end

    it "coleta os membros da classe aninhada como membros diretos do próprio alvo" do
      collector = collect_for(nested_source, target_class: "Example2::User")

      expect(collector.members.map(&:name)).to contain_exactly("name", "initialize")
      expect(collector.members.map(&:owner).uniq).to eq([nil])
    end

    # `class << self` pushes a :singleton frame, not a :class one — its defs
    # are the enclosing target's class methods and must keep being collected.
    it "não confunde `class << self` com uma classe aninhada" do
      source = <<~RUBY
        class Report
          class << self
            def build; end
          end
        end
      RUBY

      collector = collect_for(source, target_class: "Report")
      member = collector.members.find { |m| m.name == "build" }

      expect(member.kind).to eq(:class_method)
    end

    # The owner mechanism (felixefelip/rbs_infer#22) still handles nested
    # modules; only classes were promoted out of it.
    it "mantém um módulo aninhado atribuído ao alvo via owner" do
      source = <<~RUBY
        class Report
          module Formatting
            def title; end
          end
        end
      RUBY

      collector = collect_for(source, target_class: "Report")
      member = collector.members.find { |m| m.name == "title" }

      expect(member.owner).to eq("Formatting")
    end
  end

  describe "constantes (felixefelip/rbs_infer#37)" do
    def constants(source, target_class: nil)
      result = Prism.parse(source)
      visitor = described_class.new(comments: result.comments, lines: source.lines, target_class: target_class)
      result.value.accept(visitor)
      visitor.members.select { |m| m.kind == :constant }
    end

    it "coleta ConstantWriteNode com nome e nó do RHS, sem inferir o tipo ainda" do
      source = <<~RUBY
        class Color
          MAX = 8
          DEFAULT_NAME = "Blue"
        end
      RUBY

      members = constants(source, target_class: "Color")
      expect(members.map(&:name)).to eq(["MAX", "DEFAULT_NAME"])
      # signature é preenchida só depois, pelo Analyzer
      expect(members.map(&:signature)).to eq([nil, nil])
      expect(members.map { |m| m.value_node.class }).to eq([Prism::IntegerNode, Prism::StringNode])
      expect(members.map(&:visibility).uniq).to eq([:public])
    end

    it "preserva a ordem de fonte das constantes" do
      source = <<~RUBY
        class Color
          COLORS = {}.freeze
          MAX = 8
          DEFAULT_NAME = "Blue"
        end
      RUBY

      expect(constants(source, target_class: "Color").map(&:name)).to eq(["COLORS", "MAX", "DEFAULT_NAME"])
    end

    it "NÃO coleta a constante top-level que precede uma classe reaberta" do
      # `Color = Struct.new(...)` é top-level; só as constantes dentro do
      # corpo de `class Color` são membros da classe.
      source = <<~RUBY
        Color = Struct.new(:name, :value)

        class Color
          MAX = 8
        end
      RUBY

      expect(constants(source, target_class: "Color").map(&:name)).to eq(["MAX"])
    end

    it "NÃO coleta constantes de uma classe aninhada (não são membros da alvo)" do
      source = <<~RUBY
        class Outer
          OUTER_CONST = 1

          class Inner
            INNER_CONST = 2
          end
        end
      RUBY

      expect(constants(source, target_class: "Outer").map(&:name)).to eq(["OUTER_CONST"])
    end

    it "coleta constantes de um módulo aninhado com o owner correto" do
      source = <<~RUBY
        class Outer
          module Formatting
            SEP = ","
          end
        end
      RUBY

      sep = constants(source, target_class: "Outer").find { |m| m.name == "SEP" }
      expect(sep).not_to be_nil
      expect(sep.owner).to eq("Formatting")
    end

    it "coleta constante em escopo de módulo" do
      source = <<~RUBY
        module Settings
          VERSION = "1.0"
        end
      RUBY

      expect(constants(source, target_class: "Settings").map(&:name)).to eq(["VERSION"])
    end

    it "coleta ConstantPathWriteNode top-level qualificado pela classe-alvo" do
      source = <<~RUBY
        class Gadget
        end
        Gadget::MAX = 42
      RUBY

      member = constants(source, target_class: "Gadget").find { |m| m.name == "MAX" }
      expect(member).not_to be_nil
      expect(member.owner).to be_nil
      expect(member.value_node).to be_a(Prism::IntegerNode)
    end

    it "coleta ConstantPathWriteNode via self:: dentro do corpo" do
      source = <<~RUBY
        class Gadget
          self::DEFAULT = 1
        end
      RUBY

      expect(constants(source, target_class: "Gadget").map(&:name)).to eq(["DEFAULT"])
    end

    it "NÃO coleta ConstantPathWriteNode de outro namespace" do
      source = <<~RUBY
        class Gadget
        end
        Other::NOPE = 99
      RUBY

      expect(constants(source, target_class: "Gadget")).to be_empty
    end
  end

  it "gera assinatura válida para RBS parser quando tem bloco" do
    source = <<~RUBY
      module MyHelper
        def wrapper(id:, data: {}, **options, &block)
        end
      end
    RUBY

    collector = collect(source)
    member = collector.members.find { |m| m.name == "wrapper" }

    rbs_content = <<~RBS
      module MyHelper
        def #{member.signature}
      end
    RBS

    expect { RBS::Parser.parse_signature(rbs_content) }.not_to raise_error
  end

  describe "aliases (felixefelip/rbs_infer#63)" do
    it "coleta alias_method com argumentos symbol" do
      source = <<~RUBY
        class Foo
          def published?; true; end
          alias_method :was_just_published?, :published?
        end
      RUBY

      member = collect(source).members.find { |m| m.kind == :alias }
      expect(member.name).to eq("was_just_published?")
      expect(member.old_name).to eq("published?")
    end

    it "coleta alias_method com argumentos string" do
      source = <<~RUBY
        class Foo
          def published?; true; end
          alias_method "was_just_published?", "published?"
        end
      RUBY

      member = collect(source).members.find { |m| m.kind == :alias }
      expect(member.name).to eq("was_just_published?")
      expect(member.old_name).to eq("published?")
    end

    it "coleta a keyword alias" do
      source = <<~RUBY
        class Foo
          def published?; true; end
          alias just_published? published?
        end
      RUBY

      member = collect(source).members.find { |m| m.kind == :alias }
      expect(member.name).to eq("just_published?")
      expect(member.old_name).to eq("published?")
    end

    it "classifica alias dentro de `class << self` como singleton" do
      source = <<~RUBY
        class Foo
          class << self
            def build; new; end
            alias_method :make, :build
          end
        end
      RUBY

      member = collect(source).members.find { |m| m.name == "make" }
      expect(member.kind).to eq(:singleton_alias)
      expect(member.old_name).to eq("build")
    end

    it "ignora alias_method com nome dinâmico (não-literal)" do
      source = <<~RUBY
        class Foo
          def published?; true; end
          alias_method :"\#{prefix}_published?", :published?
        end
      RUBY

      expect(collect(source).members.any? { |m| m.kind == :alias }).to be(false)
    end
  end
end
