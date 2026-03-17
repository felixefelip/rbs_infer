require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::OptionalParamExtractor do
  def extract_optionals(source)
    result = Prism.parse(source)
    visitor = described_class.new
    result.value.accept(visitor)
    visitor.optional_params
  end

  it "identifica keyword params com valor default" do
    source = <<~RUBY
      class Foo
        def initialize(nome:, senha: nil)
        end
      end
    RUBY

    result = extract_optionals(source)
    expect(result).to include("senha")
    expect(result).not_to include("nome")
  end

  it "identifica múltiplos params opcionais" do
    source = <<~RUBY
      class Foo
        def initialize(a:, b: "x", c: 42, d:)
        end
      end
    RUBY

    result = extract_optionals(source)
    expect(result).to include("b", "c")
    expect(result).not_to include("a", "d")
  end

  it "retorna vazio quando não há initialize" do
    source = <<~RUBY
      class Foo
        def call; end
      end
    RUBY

    expect(extract_optionals(source)).to be_empty
  end
end
