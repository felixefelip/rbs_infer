require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Analyzer::ClassMemberCollector do
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
end
