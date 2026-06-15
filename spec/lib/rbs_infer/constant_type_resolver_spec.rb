require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::ConstantTypeResolver do
  subject(:resolver) { described_class.new(target_class: "Color") }

  # RHS node of a `NAME = <expr>` statement.
  def rhs(code)
    Prism.parse(code).value.statements.body.first.value
  end

  describe "#resolve" do
    it "infere literais via NodeTypeInferrer (sem Steep)" do
      expect(resolver.resolve(rhs("MAX = 8"))).to eq("Integer")
      expect(resolver.resolve(rhs('NAME = "Blue"'))).to eq("String")
      expect(resolver.resolve(rhs("PI = 3.14"))).to eq("Float")
      expect(resolver.resolve(rhs("FLAG = true"))).to eq("bool")
      expect(resolver.resolve(rhs("SYM = :blue"))).to eq("Symbol")
    end

    it "resolve Klass.new para a classe (single-pass, sem RBS de Klass)" do
      expect(resolver.resolve(rhs("BUILDER = Widget.new"), steep_type: "untyped")).to eq("Widget")
    end

    it "resolve new / self.new sem receiver para a classe-alvo" do
      expect(resolver.resolve(rhs("INSTANCE = new"))).to eq("Color")
      expect(resolver.resolve(rhs("INSTANCE = self.new"))).to eq("Color")
    end

    it "resolve a cadeia coletora {...}.collect { new(...) }.freeze para Array[alvo]" do
      code = 'COLORS = { "Blue" => "v1" }.collect { |name, value| new(name, value) }.freeze'
      expect(resolver.resolve(rhs(code), steep_type: "Array[Object]")).to eq("Array[Color]")
    end

    it "resolve .map { Klass.new } para Array[Klass]" do
      expect(resolver.resolve(rhs("LIST = [1, 2].map { |i| Widget.new(i) }"))).to eq("Array[Widget]")
    end

    it "trata freeze/dup como passagem do tipo do receiver" do
      expect(resolver.resolve(rhs("A = new.freeze"))).to eq("Color")
      expect(resolver.resolve(rhs("B = Widget.new.dup"))).to eq("Widget")
    end

    it "usa o tipo do Steep quando o Prism não consegue (arrays/hashes precisos)" do
      expect(resolver.resolve(rhs("WEIGHTS = [1, 2, 3]"), steep_type: "Array[Integer]")).to eq("Array[Integer]")
    end

    it "prioriza a inferência de construtor do Prism sobre o Steep" do
      # Steep, single-pass, tipa `Widget.new` como untyped; o Prism crava Widget.
      expect(resolver.resolve(rhs("X = Widget.new"), steep_type: "untyped")).to eq("Widget")
    end

    it "cai para untyped quando nada estático decide" do
      expect(resolver.resolve(rhs("X = some_runtime_call"))).to eq("untyped")
      expect(resolver.resolve(rhs("X = some_runtime_call"), steep_type: "untyped")).to eq("untyped")
    end

    it "trata RHS nil como untyped" do
      expect(resolver.resolve(nil)).to eq("untyped")
    end

    it "ignora um tipo do Steep não-utilizável (bot/void/nil) e cai para o leaf" do
      expect(resolver.resolve(rhs("MAX = 8"), steep_type: "bot")).to eq("Integer")
    end
  end
end
