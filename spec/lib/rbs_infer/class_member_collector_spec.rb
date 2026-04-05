require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::ClassMemberCollector do
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
end
